import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { AsyncDatabase, Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

function path(name: string): string {
  const created = mkdtempSync(join(tmpdir(), "zova-javascript-journal-"));
  temporaryDirectories.push(created);
  return join(created, name);
}

afterEach(() => {
  for (const created of temporaryDirectories.splice(0)) {
    rmSync(created, { force: true, recursive: true });
  }
});

function expectCode(run: () => unknown, code: string): void {
  try {
    run();
    throw new Error(`expected ${code}`);
  } catch (error) {
    expect(error).toBeInstanceOf(ZovaError);
    expect((error as ZovaError).code).toBe(code);
  }
}

describe("journal mode and checkpoint", () => {
  test("switch, report and checkpoint the set", () => {
    const file = path("journal.zova");
    const db = Database.create(file);
    try {
      expect(db.journalModes()).toEqual([{ member: "main", journalMode: "delete" }]);
      expect(db.setJournalMode("wal")).toEqual([{ member: "main", journalMode: "wal" }]);
      expectCode(() => db.setJournalMode("off"), "ZOVA_INVALID_ARGUMENT");
      expectCode(() => db.setJournalMode("bogus" as never), "ZOVA_INVALID_ARGUMENT");
      expectCode(() => db.checkpoint("bogus" as never), "ZOVA_INVALID_ARGUMENT");

      db.begin();
      expectCode(() => db.setJournalMode("delete"), "ZOVA_OBJECT_TRANSACTION_ACTIVE");
      expectCode(() => db.checkpoint(), "ZOVA_OBJECT_TRANSACTION_ACTIVE");
      db.rollback();

      db.exec("create table rows(x); insert into rows values(1)");
      const [passive] = db.checkpoint();
      expect(passive.journalMode).toBe("wal");
      expect(passive.busy).toBe(false);
      expect(passive.walFrames).toBeGreaterThan(0);
      expect(passive.checkpointedFrames).toBe(passive.walFrames);
      expect(db.checkpoint("truncate")[0].walFrames).toBe(0);
    } finally {
      db.close();
    }

    // WAL is stored in the file.
    const reopened = Database.open(file);
    try {
      expect(reopened.journalModes()[0].journalMode).toBe("wal");
      expect(reopened.setJournalMode("delete")[0].journalMode).toBe("delete");
    } finally {
      reopened.close();
    }
  });

  test("runs on AsyncDatabase", async () => {
    const db = AsyncDatabase.create(path("async.zova"));
    try {
      expect((await db.setJournalMode("wal"))[0].journalMode).toBe("wal");
      expect((await db.journalModes())[0].journalMode).toBe("wal");
      await db.exec("create table rows(x); insert into rows values(1)");
      const [member] = await db.checkpoint("passive");
      expect(member.walFrames).toBeGreaterThan(0);
      await expect(db.setJournalMode("memory")).rejects.toBeInstanceOf(ZovaError);
    } finally {
      await db.close();
    }
  });
});
