#!/usr/bin/env python3
"""Explicit-state model check of the CWAL protocol (section 8).

Breadth-first search over every interleaving of one writer, one reader and
crashes on a small set of members. Two models:

  protocol    commits, publication windows, seqlock reads, checkpoints,
              writer kills, crashes, power loss, writer reopen (discard,
              numbering) and recovery. Checks S1 (every completed read sees
              one committed state), S2 (recovery leaves each transaction on
              all of its members or none) and S3 (acknowledged commits
              survive) and S4 (no marker number is used twice). The correct
              protocol must also never be refused.

  ckpt        one member's snapshot open (with the shared checkpoint lock
              skipped and validated by the counter) against a checkpointer
              (exclusive lock, counter, read-mark scan, nBackfillAttempted,
              copy, release). Checks that no checkpoint records an intent
              past an open snapshot (what Conn.snapshotIntact tests).

  own         member ownership (acquireMember) and its interaction with
              recovery: handles of two sets that share a member, plus a
              second handle of one set, open, close and are killed at any
              step. Checks O1 (no two sets have a member open at once) and
              O2 (alone recovery never truncates a member that another
              handle has open).

  ./model.py                       # all models, then every mutation
  ./model.py --model protocol --mutation no-seq-check --trace

Each mutation removes the same mechanism as the prototype's mutation of the
same name. Mechanisms below SQLite's API (the open gate, the late -alive
check, the authorizer, the frame guard) are not modelled; the torture suite
covers them.
"""
import argparse, collections, sys, time

# ---------------------------------------------------------------------------
# Protocol model
# ---------------------------------------------------------------------------

# A frame is one commit on one member: (tid, num, mask). tid identifies the
# transaction for checking; num is its marker number (0: single-member).
P = collections.namedtuple("P", "wal synced mx db shm_ok seq hdr cross broken writer reader hist acked num_hi kills crashes used")


def visible_at(s, m, mx):
    """Frames SQLite shows for member m at wal-index mxFrame mx."""
    db, wal = s.db[m], s.wal[m]
    return db + wal[len(db):mx] if mx >= len(db) else db


def visible(s, m):
    return visible_at(s, m, s.mx[m])


def last_marker(frames):
    for f in reversed(frames):
        if f[1]:
            return f[1], f[2]
    return 0, ()


def setm(t, m, v):
    return t[:m] + (v,) + t[m + 1:]


class Protocol:
    def __init__(self, mut, members=3, txns=3, masks=((0,), (1,), (0, 1), (1, 2)), foreign=False, power=True):
        self.mut, self.n, self.k, self.masks, self.foreign, self.power = mut, members, txns, masks, foreign, power

    def m(self, name):
        return name in self.mut

    def init(self):
        e = ((),) * self.n
        z = (0,) * self.n
        return P(e, z, z, e, True, 0, z, 0, 0, ("idle", 0), ("idle",), (), frozenset(), 0, 1, 1, frozenset())

    # -- helpers ----------------------------------------------------------

    def committed(self, s):
        tids = set(s.acked)
        for m in range(self.n):
            tids.update(f[0] for f in visible(s, m))
        return tids

    def consistent(self, s, obs, committed):
        """obs[m]: frames seen on member m. Each transaction is on all of its
        members or none, and no committed transaction is missing before a
        visible later one."""
        seen = {}
        for m in range(self.n):
            for f in obs[m]:
                seen.setdefault(f[0], set()).add(m)
        for tid, mask in s.hist:
            if tid in seen and seen[tid] != set(mask):
                return f"transaction {tid} on members {sorted(seen[tid])} of {list(mask)}"
        if seen:
            newest = max(seen)
            for tid, _ in s.hist:
                if tid < newest and tid in committed and tid not in seen:
                    return f"transaction {newest} visible without earlier committed {tid}"
        return None

    def readable(self, s, role):
        if s.broken:
            return False
        if s.seq % 2 == 0 or not s.cross or self.m("no-cross-flag"):
            return True
        return role == "reader" and s.writer is not None

    def writer_counter(self, s):
        """conn.txn after open: the largest visible marker, then a new epoch."""
        hi = max(last_marker(visible(s, m))[0] for m in range(self.n))
        return hi if self.m("no-txn-epoch") else max(hi, s.num_hi)

    def recover(self, s):
        """Conn.recover on the files: every valid WAL frame counts."""
        full = [visible_at(s, m, max(len(s.wal[m]), len(s.db[m]))) for m in range(self.n)]
        markers = [last_marker(full[m]) for m in range(self.n)]
        newest = max(markers)
        wal = s.wal
        if newest[0]:
            torn = False
            for m in range(self.n):
                if markers[m][0] == newest[0] and (markers[m][1] != newest[1] or m not in newest[1]):
                    return None, "markers disagree"
                if m in newest[1] and markers[m][0] != newest[0]:
                    torn = True
            if torn and not self.m("no-marker-rollback"):
                for m in range(self.n):
                    if markers[m][0] != newest[0]:
                        continue
                    if not wal[m]:
                        return None, "no commit to remove"
                    keep = len(wal[m]) - 1
                    # backfilledPast needs the -shm; the marker-root-page
                    # comparison (pageCheckpointed) reads the database file.
                    # The repair lock keeps checkpoints out until truncation,
                    # so this step is atomic.
                    seen = s.shm_ok or not self.m("no-root-check")
                    if seen and len(s.db[m]) > keep and not self.m("no-backfill-check"):
                        return None, "torn commit already checkpointed"
                    wal = setm(wal, m, wal[m][:keep])
        mx = tuple(len(w) for w in wal)
        s = s._replace(wal=wal, synced=mx, mx=mx, shm_ok=True, seq=0, cross=0, broken=0, reader=("idle",))
        return s._replace(writer=("idle", self.writer_counter(s))), None

    # -- transitions ------------------------------------------------------

    def next(self, s):
        """Yield (action, state, violation)."""
        yield from self.writer_steps(s)
        yield from self.reader_steps(s)
        if s.writer is not None and s.kills:
            yield "kill writer", s._replace(writer=None, kills=s.kills - 1), None
        if s.writer is None and s.reader is not None and self.readable(s, "writer"):
            yield from self.writer_open(s)
        if s.crashes and (s.writer is not None or s.reader is not None):
            yield from self.crash(s)
        if s.writer is None and s.reader is None:
            r, why = self.recover(s)
            if r is None:
                yield "recover: refused", None, ("refused", why)
            else:
                v = self.consistent(r, [visible(r, m) for m in range(self.n)], set())
                if v is None:
                    lost = [t for t in r.acked if all(t not in {f[0] for f in visible(r, m)} for m in range(self.n))]
                    v = f"acknowledged transaction {lost[0]} lost" if lost else None
                yield "recover", r, ("S2/S3", v) if v else None
        if self.foreign or self.m("no-ckpt-gate"):
            # A checkpoint the gate would refuse: a reader's or an outside
            # connection's, at any time.
            for m in range(self.n):
                if s.reader is not None and len(s.db[m]) < s.mx[m]:
                    yield f"foreign checkpoint m{m}", s._replace(db=setm(s.db, m, visible(s, m))), None

    def writer_open(self, s):
        seq = s.seq + 1 if s.seq % 2 else s.seq
        wal, synced = s.wal, s.synced
        if not self.m("no-discard-unpublished"):
            wal = tuple(w[:s.mx[m]] for m, w in enumerate(wal))
            synced = tuple(min(x, s.mx[m]) for m, x in enumerate(synced))
        s = s._replace(seq=seq, wal=wal, synced=synced)
        yield "writer open", s._replace(writer=("idle", self.writer_counter(s))), None

    def crash(self, s):
        dead = s._replace(writer=None, reader=None, crashes=s.crashes - 1)
        yield "kill all", dead, None
        if not self.power:
            return
        # Power loss: unsynced frames may be lost; the -shm may be lost.
        opts = [[w] if len(w) == s.synced[m] else [w, w[:s.synced[m]]] for m, w in enumerate(s.wal)]
        def walk(i, acc):
            if i == self.n:
                yield tuple(acc)
            else:
                for w in opts[i]:
                    yield from walk(i + 1, acc + [w])
        for wal in walk(0, []):
            yield "power loss", dead._replace(wal=wal, synced=tuple(len(w) for w in wal), shm_ok=False), None

    def writer_steps(self, s):
        w = s.writer
        if w is None:
            return
        if w[0] == "idle":
            counter = w[1]
            if len(s.hist) < self.k and not s.broken:
                tid = len(s.hist) + 1
                for mask in self.masks:
                    cross = len(mask) >= 2
                    num = counter + 1 if cross and not self.m("no-markers") else 0
                    c2 = num or counter
                    bad = ("S4", f"marker number {num} reused by t{tid}") if num and num in s.used else None
                    yield f"begin t{tid} {list(mask)}", s._replace(
                        writer=("c", c2, tid, mask, num, 0, False, False), used=s.used | {num} if num else s.used,
                        hist=s.hist + ((tid, mask),), num_hi=max(s.num_hi, c2)), bad
            if not s.broken and any(len(s.db[m]) < s.mx[m] for m in range(self.n)):
                yield "checkpoint", s._replace(db=tuple(visible(s, m) for m in range(self.n))), None
            return
        _, counter, tid, mask, num, step, any_frame, win = w
        steps = [(op, m) for m in mask for op in "wsp"] + [("2", None)]
        op, m = steps[step]
        nxt = lambda **kw: w[:5] + (step + 1, kw.get("any_frame", any_frame), kw.get("win", win))
        if op == "w":
            wal = setm(s.wal, m, s.wal[m][:s.mx[m]] + ((tid, num, mask),))
            yield f"t{tid} write m{m}", s._replace(wal=wal, synced=setm(s.synced, m, min(s.synced[m], s.mx[m])),
                                                   writer=nxt(any_frame=True)), None
        elif op == "s":
            ok = s._replace(synced=setm(s.synced, m, len(s.wal[m])))
            cross = len(mask) >= 2
            if not win and not self.m("no-gate") and (cross or not self.m("no-solo-window")):
                ok = ok._replace(hdr=s.mx, cross=int(cross), seq=s.seq + 1)
                yield f"t{tid} sync m{m}, window opens", ok._replace(writer=nxt(win=True)), None
            else:
                yield f"t{tid} sync m{m}", ok._replace(writer=nxt()), None
            # The sync fails: SQLite rolls back; the rollback hook runs.
            f = s._replace(writer=("idle", counter))
            if cross and any_frame:
                f = f._replace(broken=1)
            if win:
                f = f._replace(seq=f.seq + 1)
            yield f"t{tid} sync m{m} fails", f, None
        elif op == "p":
            yield f"t{tid} publish m{m}", s._replace(mx=setm(s.mx, m, len(s.wal[m])), writer=nxt()), None
        else:
            yield f"t{tid} phase two", s._replace(seq=s.seq + 1 if win else s.seq, writer=("idle", counter),
                                                  acked=s.acked | {tid}), None

    def reader_steps(self, s):
        r = s.reader
        if r is None:
            return
        if r[0] == "idle":
            if not self.readable(s, "reader"):
                return  # Broken: refused, not a violation.
            if s.seq % 2 == 0:
                yield "read: begin", s._replace(reader=("pin", s.seq, (), not self.m("no-seq-check"))), None
            elif self.m("no-snapshot-open"):
                yield "read: begin in window, pin", s._replace(reader=("pin", s.seq, (), False)), None
            else:
                yield "read: copy headers", s._replace(reader=("odd", s.seq, s.hdr)), None
        elif r[0] == "pin":
            _, s1, obs, check = r
            m = len(obs)
            if m < self.n:
                yield f"read: pin m{m}", s._replace(reader=("pin", s1, obs + (visible(s, m),), check)), None
            elif check and s.seq != s1:
                yield "read: seq changed, retry", s._replace(reader=("idle",)), None
            else:
                yield from self.finish_read(s, obs)
        elif r[0] == "odd":
            _, s1, hdrs = r
            if s.seq != s1:
                yield "read: seq changed, retry", s._replace(reader=("idle",)), None
            elif any(len(s.db[m]) > hdrs[m] for m in range(self.n)):
                yield "read: snapshot open fails", s._replace(reader=("wait", s1)), None
            else:
                yield from self.finish_read(s, tuple(visible_at(s, m, hdrs[m]) for m in range(self.n)))
        elif r[0] == "wait":
            if s.seq != r[1]:
                yield "read: window ended", s._replace(reader=("idle",)), None

    def finish_read(self, s, obs):
        v = self.consistent(s, obs, self.committed(s))
        yield "read: done " + " ".join(f"m{m}={[f[0] for f in o]}" for m, o in enumerate(obs)), \
            s._replace(reader=("idle",)), ("S1", v) if v else None


# ---------------------------------------------------------------------------
# Checkpoint-counter model
# ---------------------------------------------------------------------------

# One member. The WAL has frames 1..mx; the reader opens a snapshot at
# snap < mx (it started inside a window). The checkpointer copies frames up
# to the smallest read mark it sees.
C = collections.namedtuple("C", "active started attempted mark rpc rstart rlock wpc wlimit wcount")


class Ckpt:
    """Sequentially consistent (the prototype issues full barriers at both
    points where this matters; see ioShmLock and ckptLockShared).

    Reader (sqlite3_snapshot_open with ckptLockShared):
      take:    load counter; active != 0 (or no-ckpt-skip) -> take SQLite's
               real shared lock instead, which waits for and then excludes
               the checkpointer's exclusive lock; else remember started
      check:   attempted > snap -> open fails (SQLITE_ERROR_SNAPSHOT)
      mark:    store read mark = snap
      release: skipped lock: load counter, started changed -> retry;
               real lock: unlock
    Checkpointer (exclusive checkpoint lock through ioShmLock), twice:
      lock, inc (active += 1, started += 1), scan (limit = min(mx, mark)),
      intent (nBackfillAttempted = limit), dec (active -= 1) and unlock.
    ckpt-inc-late moves inc after scan; ckpt-dec-early moves dec before intent.
    """
    MX, SNAP = 3, 1

    def __init__(self, mut):
        self.mut = mut
        self.order = ["lock", "inc", "scan", "intent", "dec"]
        if "ckpt-inc-late" in mut:
            self.order = ["lock", "scan", "inc", "intent", "dec"]
        if "ckpt-dec-early" in mut:
            self.order = ["lock", "inc", "scan", "dec", "intent"]

    def init(self):
        return C(0, 0, 0, None, "take", 0, False, 0, None, 2)

    def next(self, s):
        m = self.mut
        holding = 0 < s.wpc  # checkpointer holds the exclusive lock
        if s.rpc == "take":
            if s.active or "no-ckpt-skip" in m:
                if not holding:
                    yield "reader takes real shared lock", s._replace(rpc="check", rlock=True), None
            else:
                yield "reader skips lock", s._replace(rpc="check", rstart=s.started), None
        elif s.rpc == "check":
            if s.attempted > self.SNAP:
                yield "reader open fails", s._replace(rpc="done", rlock=False), None
            else:
                yield "reader check ok", s._replace(rpc="mark"), None
        elif s.rpc == "mark":
            yield "reader stores read mark", s._replace(rpc="release", mark=self.SNAP), None
        elif s.rpc == "release":
            if s.rlock:
                yield "reader unlocks: open", s._replace(rpc="open", rlock=False), None
            elif s.started != s.rstart and "no-ckpt-validate" not in m:
                yield "reader: checkpoint started, retry", s._replace(rpc="take", mark=None), None
            else:
                yield "reader: open", s._replace(rpc="open"), None
        if s.wcount:
            op = self.order[s.wpc]
            nxt = (s.wpc + 1) % len(self.order)
            if op == "lock":
                if not s.rlock:
                    yield "ckpt takes exclusive lock", s._replace(wpc=nxt), None
            elif op == "inc":
                yield "ckpt counter += 1", s._replace(active=s.active + 1, started=s.started + 1, wpc=nxt), None
            elif op == "scan":
                limit = self.MX if s.mark is None else min(self.MX, s.mark)
                yield f"ckpt scans read marks: limit {limit}", s._replace(wlimit=limit, wpc=nxt), None
            elif op == "intent":
                yield "ckpt records nBackfillAttempted", s._replace(attempted=max(s.attempted, s.wlimit), wpc=nxt, wcount=s.wcount - (nxt == 0)), None
            else:
                yield "ckpt counter -= 1, unlock", s._replace(active=s.active - 1, wpc=nxt, wcount=s.wcount - (nxt == 0)), None
        if s.rpc == "open" and s.attempted > self.SNAP:
            yield "violation", s, ("snapshot", f"nBackfillAttempted {s.attempted} past open snapshot {self.SNAP}")


# ---------------------------------------------------------------------------
# Member-ownership model
# ---------------------------------------------------------------------------

# Per member m: own[m], the flock holders of m's -cwal-own as (handle, "EX"
# or "SH"); ident[m], its recorded identity (None, ("partial", set) or a
# set); gate[m], the handle holding m's -cwal-mgate. alive[x]: holders of
# set x's -cwal-alive. A handle is (pc, i, owned, opens): pc its step, i the
# member it is acquiring, owned the members whose -cwal-own it holds.
O = collections.namedtuple("O", "own ident gate alive h kills")


class Own:
    """acquireMember, per member in set order:
      gate:   take -cwal-mgate (blocking)
      try:    flock EX|NB on -cwal-own; free -> write, else cmp
      write:  pwrite the identity (a kill leaves it partial)
      trunc:  ftruncate to its length
      unlock: flock(SH) on an EX lock first unlocks (not atomic)
      sh:     ... then takes SH (blocking); release the gate
      cmp:    recorded identity != ours -> MemberOwned (refused)
      shnb:   flock SH|NB; failure -> refused; release the gate
    A refused open releases everything it holds. Then openCoordination:
    -alive EX|NB -> recover (alone) -> SH; else SH (blocking). close():
    unmap and leave -alive, then give up the members. A kill drops every
    flock at once; the identity files stay."""
    SETS = {"A": (0, 1), "B": (1, 2)}
    # Steps in which a handle has its members open: mapped, and (own-early)
    # still mapped after giving up the members.
    OPEN = ("mapped", "unmap")
    HANDLES = (("A1", "A"), ("A2", "A"), ("B1", "B"))

    def __init__(self, mut, opens=2, kills=2):
        self.mut, self.opens, self.kills = mut, opens, kills

    def init(self):
        n = 3
        return O((frozenset(),) * n, (None,) * n, (None,) * n, (("A", frozenset()), ("B", frozenset())),
                 tuple(("idle", 0, frozenset(), self.opens) for _ in self.HANDLES), self.kills)

    def alive_of(self, s, x):
        return dict(s.alive)[x]

    def set_alive(self, s, x, v):
        return s._replace(alive=tuple((k, v if k == x else w) for k, w in s.alive))

    def seth(self, s, k, v):
        return s._replace(h=setm(s.h, k, v))

    def release(self, s, k):
        """Handle k drops every flock it holds (refusal, kill)."""
        own = tuple(frozenset(e for e in o if e[0] != k) for o in s.own)
        gate = tuple(None if g == k else g for g in s.gate)
        s = s._replace(own=own, gate=gate)
        for x, w in s.alive:
            s = self.set_alive(s, x, frozenset(e for e in w if e[0] != k))
        return s

    def mapped(self, s):
        return [(k, self.HANDLES[k][1]) for k, hs in enumerate(s.h) if hs[0] in self.OPEN]

    def next(self, s):
        maps = self.mapped(s)
        for m in range(3):
            sets = {x for k, x in maps if m in self.SETS[x]}
            if len(sets) > 1:
                yield "violation", None, ("O1", f"member m{m} open in sets {sorted(sets)}")
                return
        for k, (name, x) in enumerate(self.HANDLES):
            pc, i, owned, opens = s.h[k]
            ms = self.SETS[x]
            if pc != "idle" and s.kills:
                yield f"kill {name}", self.seth(self.release(s, k), k, ("idle", 0, frozenset(), opens))._replace(kills=s.kills - 1), None
            yield from self.step(s, k, name, x, ms, pc, i, owned, opens)

    def step(self, s, k, name, x, ms, pc, i, owned, opens):
        m = ms[i] if i < len(ms) else None
        others = lambda o: [e for e in o if e[0] != k]
        go = lambda pc2, i2=i, owned2=owned, st=s: self.seth(st, k, (pc2, i2, owned2, opens))
        refuse = lambda why: (f"{name} refused at m{m}: {why}",
                              self.seth(self.release(s, k), k, ("idle", 0, frozenset(), opens)), None)
        def acquired(st):
            # Member m is owned; release its gate, go to the next member.
            st = st._replace(gate=setm(st.gate, m, None))
            return go("gate" if i + 1 < len(ms) else "alive", i + 1, owned | {m}, st)
        if pc == "idle":
            if opens:
                start = "alive" if "no-ownership" in self.mut else "gate"
                yield f"{name} opens", self.seth(s, k, (start, 0, frozenset(), opens - 1)), None
        elif pc == "gate":
            if "no-mgate" in self.mut:
                yield f"{name} m{m}: (no gate)", go("try"), None
            elif s.gate[m] is None:
                yield f"{name} m{m}: takes gate", go("try", st=s._replace(gate=setm(s.gate, m, k))), None
        elif pc == "try":
            if not others(s.own[m]):
                yield f"{name} m{m}: EX", go("write", st=s._replace(own=setm(s.own, m, s.own[m] | {(k, "EX")}))), None
            else:
                yield f"{name} m{m}: owned, compare", go("cmp"), None
        elif pc == "write":
            yield f"{name} m{m}: pwrite identity", go("trunc", st=s._replace(ident=setm(s.ident, m, ("partial", x)))), None
        elif pc == "trunc":
            yield f"{name} m{m}: ftruncate", go("unlock", st=s._replace(ident=setm(s.ident, m, x))), None
        elif pc == "unlock":
            yield f"{name} m{m}: EX released for SH", go("sh", st=s._replace(own=setm(s.own, m, frozenset(others(s.own[m]))))), None
        elif pc == "sh":
            if not any(e[1] == "EX" for e in others(s.own[m])):
                yield f"{name} m{m}: SH", acquired(s._replace(own=setm(s.own, m, s.own[m] | {(k, "SH")}))), None
        elif pc == "cmp":
            if s.ident[m] == x or "no-identity-check" in self.mut:
                yield f"{name} m{m}: identity matches", go("shnb"), None
            else:
                yield refuse("MemberOwned")
        elif pc == "shnb":
            if any(e[1] == "EX" for e in others(s.own[m])):
                yield refuse("SH|NB failed")
            else:
                yield f"{name} m{m}: SH|NB", acquired(s._replace(own=setm(s.own, m, s.own[m] | {(k, "SH")}))), None
        elif pc == "alive":
            w = self.alive_of(s, x)
            if not w:
                yield f"{name} -alive EX (alone)", go("recover", st=self.set_alive(s, x, frozenset({(k, "EX")}))), None
            elif not any(e[1] == "EX" for e in w):
                yield f"{name} -alive SH", go("mapped", st=self.set_alive(s, x, w | {(k, "SH")})), None
        elif pc == "recover":
            for j, hs in enumerate(s.h):
                if j != k and hs[0] in self.OPEN and set(self.SETS[self.HANDLES[j][1]]) & set(ms):
                    yield f"{name} recovers", None, ("O2", f"{name} truncates members of {x} while {self.HANDLES[j][0]} has "
                                                      f"m{sorted(set(self.SETS[self.HANDLES[j][1]]) & set(ms))[0]} open")
                    return
            w = frozenset(e for e in self.alive_of(s, x) if e[0] != k) | {(k, "SH")}
            yield f"{name} recovers, -alive SH", go("mapped", st=self.set_alive(s, x, w)), None
        elif pc == "mapped":
            if "own-early" in self.mut:
                own = tuple(frozenset(e for e in o if e[0] != k) for o in s.own)
                yield f"{name} closes: members first", go("unmap", owned2=frozenset(), st=s._replace(own=own)), None
            else:
                yield f"{name} closes: unmap, leave -alive", go("unmapped", st=self.set_alive(s, x, frozenset(e for e in self.alive_of(s, x) if e[0] != k))), None
        elif pc == "unmapped":
            own = tuple(frozenset(e for e in o if e[0] != k) for o in s.own)
            yield f"{name} closes: gives up members", self.seth(s._replace(own=own), k, ("idle", 0, frozenset(), opens)), None
        elif pc == "unmap":
            st = self.set_alive(s, x, frozenset(e for e in self.alive_of(s, x) if e[0] != k))
            yield f"{name} closes: unmap, leave -alive", self.seth(st, k, ("idle", 0, frozenset(), opens)), None


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------


def search(model, trace=False, limit=5_000_000):
    start = model.init()
    parent = {start: None}
    queue = collections.deque([start])
    refused = 0
    while queue:
        s = queue.popleft()
        for action, t, bad in model.next(s):
            if bad and bad[0] == "refused":
                refused += 1
                bad = None if isinstance(model, Protocol) and (model.foreign or model.mut) else bad
            if bad:
                path = [action]
                x = s
                while parent[x] is not None:
                    x, a = parent[x]
                    path.append(a)
                return {"states": len(parent), "violation": f"{bad[0]}: {bad[1]}", "trace": path[::-1], "refused": refused}
            if t is not None and t not in parent:
                parent[t] = (s, action)
                if len(parent) > limit:
                    return {"states": len(parent), "violation": "state limit reached", "trace": [], "refused": refused}
                queue.append(t)
    return {"states": len(parent), "violation": None, "trace": [], "refused": refused}


PROTOCOL_MUTATIONS = ["no-gate", "no-solo-window", "no-seq-check", "no-snapshot-open", "no-markers",
                      "no-marker-rollback", "no-cross-flag", "no-discard-unpublished", "no-txn-epoch",
                      "no-ckpt-gate", "no-backfill-check", "no-root-check"]
CKPT_MUTATIONS = ["no-ckpt-validate", "no-ckpt-skip", "ckpt-inc-late", "ckpt-dec-early"]
OWN_MUTATIONS = ["no-ownership", "no-mgate", "no-identity-check", "own-early"]


def run(name, model, trace):
    t = time.time()
    r = search(model)
    status = "VIOLATION " + r["violation"] if r["violation"] else "ok"
    extra = f" refused={r['refused']}" if r["refused"] else ""
    print(f"{name:42} states={r['states']:>9} {time.time() - t:6.1f}s  {status}{extra}", flush=True)
    if trace and r["trace"]:
        for i, a in enumerate(r["trace"], 1):
            print(f"    {i:3} {a}")
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=["protocol", "ckpt", "own", "all"], default="all")
    ap.add_argument("--mutation", default="", help="comma list; default: none, then each in turn")
    ap.add_argument("--txns", type=int, default=3)
    ap.add_argument("--trace", action="store_true")
    a = ap.parse_args()
    bad = 0
    if a.model in ("protocol", "all"):
        if a.mutation:
            run(f"protocol {a.mutation}", Protocol(set(a.mutation.split(",")), txns=a.txns), a.trace)
        else:
            bad += run("protocol", Protocol(set(), txns=a.txns), a.trace)["violation"] is not None
            bad += run("protocol, foreign checkpoints, no power loss", Protocol(set(), txns=a.txns, foreign=True, power=False), a.trace)["violation"] is not None
            bad += run("protocol, foreign checkpoints and power loss", Protocol(set(), txns=a.txns, foreign=True), a.trace)["violation"] is not None
            for mu in PROTOCOL_MUTATIONS:
                kw = {"foreign": True, "power": False} if mu == "no-backfill-check" else {"foreign": True} if mu == "no-root-check" else {}
                # The root-page check refuses a reader's checkpoint of a torn
                # commit, which hides a missing gate; test the gate without it.
                muts = {mu, "no-root-check"} if mu == "no-ckpt-gate" else {mu}
                label = f"protocol {mu}" + (" (foreign)" if kw else "") + (" (with no-root-check)" if len(muts) > 1 else "")
                r = run(label, Protocol(muts, txns=a.txns, **kw), a.trace)
                bad += r["violation"] is None
    if a.model in ("ckpt", "all"):
        if a.mutation and a.model == "ckpt":
            run(f"ckpt {a.mutation}", Ckpt(set(a.mutation.split(","))), a.trace)
        elif not a.mutation:
            bad += run("ckpt", Ckpt(set()), a.trace)["violation"] is not None
            for mu in CKPT_MUTATIONS:
                r = run(f"ckpt {mu}", Ckpt({mu}), a.trace)
                bad += (r["violation"] is None) != (mu == "no-ckpt-skip")
    if a.model in ("own", "all"):
        if a.mutation and a.model == "own":
            run(f"own {a.mutation}", Own(set(a.mutation.split(","))), a.trace)
        elif not a.mutation:
            bad += run("own", Own(set()), a.trace)["violation"] is not None
            for mu in OWN_MUTATIONS:
                bad += run(f"own {mu}", Own({mu}), a.trace)["violation"] is None
    sys.exit(1 if bad else 0)


main()
