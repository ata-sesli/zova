import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { AsyncDatabase, Database, ZovaError } from "../js/index.js";
import type { Progress } from "../js/index.js";

const temporaryDirectories: string[] = [];

function directory(): string {
  const created = mkdtempSync(join(tmpdir(), "zova-javascript-progress-"));
  temporaryDirectories.push(created);
  return created;
}

afterEach(() => {
  for (const created of temporaryDirectories.splice(0)) {
    rmSync(created, { force: true, recursive: true });
  }
});

/** Verify covers far more items than the 101 whole-percent steps Zova forwards. */
function createWithEntries(path: string): void {
  const db = Database.create(path);
  const entries = Array.from({ length: 1000 }, (_, index) => {
    const key = new Uint8Array(8);
    new DataView(key.buffer).setBigUint64(0, BigInt(index));
    return { key, value: new TextEncoder().encode("progress") };
  });
  db.kvPutMany(new TextEncoder().encode("progress"), entries);
  db.close();
}

/** Each phase/member group keeps its total, never decreases, and ends at total. */
function expectWellFormed(events: Progress[]): void {
  expect(events.length).toBeGreaterThan(0);
  events.forEach((event, index) => {
    expect(event.done).toBeLessThanOrEqual(event.total);
    const next = events[index + 1];
    if (next !== undefined && next.phase === event.phase && next.member === event.member) {
      expect(next.total).toBe(event.total);
      expect(next.done).toBeGreaterThanOrEqual(event.done);
    } else {
      expect(event.done).toBe(event.total);
    }
  });
}

describe("progress", () => {
  test("backup and compact deliver every event before the promise settles", async () => {
    const dir = directory();
    createWithEntries(join(dir, "source.zova"));
    const db = AsyncDatabase.open(join(dir, "source.zova"));

    const events: Progress[] = [];
    await db.backupTo(join(dir, "backup.zova"), true, {
      progress: (event) => events.push(event),
    });
    expectWellFormed(events);
    expect(events[0]).toMatchObject({ phase: "copy", member: "main" });
    const verify = events.filter((event) => event.phase === "verify");
    expect(verify.length).toBeGreaterThan(1);
    expect(verify.length).toBeLessThanOrEqual(102);
    for (const event of verify) {
      expect(event.member).toBeNull();
      expect(event.total).toBeGreaterThanOrEqual(1000);
    }

    const compactEvents: Progress[] = [];
    await db.compactTo(join(dir, "compact.zova"), true, {
      progress: (event) => compactEvents.push(event),
    });
    expectWellFormed(compactEvents);
    await db.close();
  });

  test("an aborted signal cancels with ZOVA_INTERRUPTED and leaves no destination", async () => {
    const dir = directory();
    createWithEntries(join(dir, "source.zova"));
    const db = AsyncDatabase.open(join(dir, "source.zova"));
    const controller = new AbortController();
    controller.abort();

    const backup = join(dir, "backup.zova");
    const error = await db.backupTo(backup, true, { signal: controller.signal }).catch((e) => e);
    expect(error).toBeInstanceOf(ZovaError);
    expect((error as ZovaError).code).toBe("ZOVA_INTERRUPTED");
    expect(existsSync(backup)).toBe(false);

    await db.exec("SELECT 1");
    await db.close();
  });

  test("an exception thrown by the callback rejects with that exception", async () => {
    const dir = directory();
    createWithEntries(join(dir, "source.zova"));
    const db = AsyncDatabase.open(join(dir, "source.zova"));
    const failure = new Error("stop");
    let calls = 0;
    await expect(
      db.compactTo(join(dir, "compact.zova"), true, {
        progress: () => {
          calls += 1;
          throw failure;
        },
      }),
    ).rejects.toBe(failure);
    expect(calls).toBe(1);
    await db.close();
  });

  test("migration reports progress and a cancelled migration leaves the source unchanged", async () => {
    const dir = directory();
    const source = join(dir, "source.zova");
    copyFileSync(join(import.meta.dir, "..", "..", "..", "tests", "fixtures", "format-9.zova"), source);
    const before = readFileSync(source);
    const destination = join(dir, "migrated.zova");

    const controller = new AbortController();
    controller.abort();
    const error = await AsyncDatabase.migrateDatabase(source, destination, true, undefined, {
      signal: controller.signal,
    }).catch((e) => e);
    expect((error as ZovaError).code).toBe("ZOVA_INTERRUPTED");
    expect(existsSync(destination)).toBe(false);
    expect(readFileSync(source).equals(before)).toBe(true);

    const events: Progress[] = [];
    await AsyncDatabase.migrateDatabase(source, destination, true, undefined, {
      progress: (event) => events.push(event),
    });
    expectWellFormed(events);
    const phases = new Set(events.map((event) => event.phase));
    for (const phase of ["copy", "migrate", "verify", "publish"]) {
      expect(phases.has(phase as Progress["phase"])).toBe(true);
    }
    expect(events.at(-1)).toMatchObject({ phase: "publish", member: null });
  });
});
