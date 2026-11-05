import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { AsyncDatabase, Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

function path(name: string): string {
  const created = mkdtempSync(join(tmpdir(), "zova-javascript-reclaim-"));
  temporaryDirectories.push(created);
  return join(created, name);
}

afterEach(() => {
  for (const created of temporaryDirectories.splice(0)) {
    rmSync(created, { force: true, recursive: true });
  }
});

/** Leaves about 300 free pages in the main database. */
const LEAVE_FREE_PAGES =
  "create table scratch(data blob); " +
  "with recursive n(i) as (select 1 union all select i + 1 from n where i < 300) " +
  "insert into scratch select zeroblob(4000) from n; " +
  "drop table scratch";

describe("reclaimSpace", () => {
  test("releases free pages in bounded steps", () => {
    const db = Database.create(path("reclaim.zova"));
    try {
      db.exec(LEAVE_FREE_PAGES);
      const bounded = db.reclaimSpace({ maxPages: 100, stepPages: 30 });
      expect(bounded).toHaveLength(1);
      const [first] = bounded;
      expect(first.member).toBe("main");
      expect(first.autoVacuum).toBe("incremental");
      expect(first.pageSize).toBe(4096);
      expect(first.pagesReleased).toBe(100);
      expect(first.freePagesLeft).toBeGreaterThan(0);

      const [rest] = db.reclaimSpace();
      expect(rest.pagesReleased).toBe(first.freePagesLeft);
      expect(rest.freePagesLeft).toBe(0);

      db.begin();
      try {
        db.reclaimSpace();
        throw new Error("expected ZOVA_OBJECT_TRANSACTION_ACTIVE");
      } catch (error) {
        expect(error).toBeInstanceOf(ZovaError);
        expect((error as ZovaError).code).toBe("ZOVA_OBJECT_TRANSACTION_ACTIVE");
      }
      db.rollback();

      for (const maxPages of [-1, 1.5, Number.MAX_SAFE_INTEGER + 2]) {
        expect(() => db.reclaimSpace({ maxPages })).toThrow(ZovaError);
      }
    } finally {
      db.close();
    }
  });

  test("reports a none-mode file and runs on AsyncDatabase", async () => {
    const db = AsyncDatabase.create(path("none.zova"));
    try {
      await db.exec("pragma auto_vacuum = none; vacuum");
      await db.exec(LEAVE_FREE_PAGES);
      const members = await db.reclaimSpace();
      expect(members).toHaveLength(1);
      expect(members[0].autoVacuum).toBe("none");
      expect(members[0].pagesReleased).toBe(0);
      expect(members[0].freePagesLeft).toBeGreaterThan(0);
      await expect(db.reclaimSpace({ maxPages: -1 })).rejects.toBeInstanceOf(ZovaError);
    } finally {
      await db.close();
    }
  });
});
