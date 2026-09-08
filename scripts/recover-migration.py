#!/usr/bin/env python3
"""Offline recovery of one interrupted Zova migration (Python standard library)."""
import argparse
import os
from pathlib import Path
import stat

MAGIC = b"zova-migration-recovery-v1\n"


def regular(path: Path) -> bool:
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except FileNotFoundError:
        return False


def same_file(left: Path, right: Path) -> bool:
    # Compare device AND inode. Reject symlinks, even ones targeting witnesses.
    return regular(left) and regular(right) and os.path.samefile(left, right)


def recover(destination: Path) -> str:
    if destination.suffix != ".zova":
        raise ValueError("destination must end in .zova")
    directory = Path(str(destination) + ".migration-recovery")
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("no migration recovery directory (or it is a symlink)")
    owner = directory / "owner"
    if not regular(owner) or owner.read_bytes() != MAGIC:
        raise ValueError("unrecognized ownership marker; nothing removed")

    finals = [destination] + [
        destination.with_name(f"{destination.stem}.{suffix}.zova")
        for suffix in ("objects", "vectors", "graphs")
    ]
    allowed = {"owner"}
    for final in finals:
        allowed.update((final.name, "reserved-" + final.name))
        allowed.update(final.name + suffix for suffix in ("-journal", "-wal", "-shm"))
    entries = list(directory.iterdir())
    if any(p.name not in allowed or not regular(p) for p in entries):
        raise ValueError("unexpected recovery contents; nothing removed")

    committed = same_file(destination, directory / destination.name)
    has_witnesses = any(p.name != "owner" for p in entries)
    if (os.path.lexists(destination) and not committed and has_witnesses
            and not same_file(destination, directory / ("reserved-" + destination.name))):
        raise ValueError("main destination ownership is unknown; nothing removed")
    remove = []
    # Validate the entire set before removing anything. Missing finals are fine
    # after a kill between unlinking a reservation and linking the new member.
    for final in finals:
        reservation = directory / ("reserved-" + final.name)
        staged = directory / final.name
        if not reservation.exists() and not staged.exists():
            continue  # This store was not part of the migration.
        if committed:
            if not same_file(final, staged):
                raise ValueError(f"published set changed at {final}; nothing removed")
        elif os.path.lexists(final):
            if not (same_file(final, reservation) or same_file(final, staged)):
                raise ValueError(f"unrelated or replaced destination {final}; nothing removed")
            remove.append(final)
    for final in remove:
        final.unlink()
    # Do not recursively remove the directory: unexpected new files must stop
    # cleanup. The operator must stop all users of these paths before recovery.
    # Keep the main inode as the commit proof until all store witnesses are
    # removed, so interruption of recovery cannot delete a committed store.
    entries.sort(key=lambda p: (
        p.name == "owner", p.name == destination.name,
        not p.name.startswith("reserved-"),
    ))
    for entry in entries:
        entry.unlink()
    directory.rmdir()
    if not has_witnesses:
        return "ownership cleanup completed; existing destinations untouched"
    return "published migration retained" if committed else "interrupted output removed; migration may be retried"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        print(recover(args.destination))
    except (OSError, ValueError) as error:
        parser.exit(1, f"recovery refused: {error}\n")
