import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { AsyncDatabase, Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

function path(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-async-"));
  temporaryDirectories.push(directory);
  return join(directory, "async.zova");
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("AsyncDatabase", () => {
  test("runs queued work in FIFO order and propagates native rejections", async () => {
    const databasePath = path();
    const db = AsyncDatabase.create(databasePath);
    const first = db.exec("CREATE TABLE ordered(value INTEGER NOT NULL)");
    const second = db.exec("INSERT INTO ordered VALUES (1)");
    const third = db.exec("INSERT INTO ordered VALUES (2)");
    await Promise.all([third, first, second]);
    await expect(
      db.exec("INSERT INTO missing_table VALUES (1)"),
    ).rejects.toBeInstanceOf(ZovaError);
    await db.close();

    const reopened = Database.open(databasePath);
    const statement = reopened.prepare(
      "SELECT group_concat(value, ',') FROM ordered ORDER BY rowid",
    );
    expect(statement.step()).toBe("row");
    expect(statement.columnText(0)).toBe("1,2");
    statement.close();
    reopened.close();
  });

  test("keeps the event loop responsive and waits for pending work on close", async () => {
    const db = AsyncDatabase.create(path());
    let timerRan = false;
    const timer = new Promise<void>((resolve) => {
      setTimeout(() => {
        timerRan = true;
        resolve();
      }, 0);
    });
    const longQuery = db.exec(`
      WITH RECURSIVE count(x) AS (
        VALUES(0)
        UNION ALL
        SELECT x + 1 FROM count WHERE x < 1000000
      )
      SELECT sum(x) FROM count
    `);
    const closing = db.close();
    await timer;
    expect(timerRan).toBe(true);
    await expect(db.exec("SELECT 1")).rejects.toBeInstanceOf(ZovaError);
    await longQuery;
    await closing;
    expect(db.closed).toBe(true);
    await db.close();
  });

  test("moves object bytes through worker tasks", async () => {
    const db = AsyncDatabase.create(path());
    const bytes = new TextEncoder().encode("asynchronous object");
    const id = await db.putObject(bytes);
    expect(id).toHaveLength(32);
    expect(await db.getObject(id)).toEqual(bytes);
    await db.close();
  });

  test("queues native vector batches and graph batches/walks", async () => {
    const databasePath = path();
    const setup = Database.create(databasePath);
    setup.createVectorCollection("vectors", {
      dimensions: 2,
      metric: "cosine",
      elementType: "f32",
    });
    setup.createGraph("knowledge");
    setup.close();

    const db = AsyncDatabase.open(databasePath);
    await db.putVectors("vectors", [
      { id: "north", values: new Float32Array([1, 0]) },
      { id: "east", values: new Float32Array([0, 1]) },
    ]);
    expect(
      (await db.searchVectors("vectors", new Float32Array([1, 0]), {
        limit: 1,
      }))[0]?.id,
    ).toBe("north");

    await db.putGraphNodes([
      {
        graphName: "knowledge",
        nodeId: "root",
        kind: "document",
        targetType: "none",
      },
      {
        graphName: "knowledge",
        nodeId: "child",
        kind: "section",
        targetType: "none",
      },
    ]);
    await db.putGraphEdges([
      {
        graphName: "knowledge",
        fromNodeId: "root",
        edgeType: "contains",
        toNodeId: "child",
      },
    ]);
    expect(
      (await db.graphWalk({
        graphName: "knowledge",
        startNodeId: "root",
        maxDepth: 1,
        limit: 10,
      })).map((item) => item.nodeId),
    ).toEqual(["root", "child"]);
    await db.close();
  });

  test("restores backups asynchronously", async () => {
    const source = path();
    const backup = path();
    const restored = path();
    const setup = Database.create(source);
    setup.exec("CREATE TABLE notes(body TEXT NOT NULL)");
    setup.exec("INSERT INTO notes VALUES ('hello')");
    setup.backupTo(backup);
    setup.close();

    await AsyncDatabase.restoreBackup(backup, restored);
    const database = Database.open(restored);
    const statement = database.prepare("SELECT body FROM notes");
    expect(statement.step()).toBe("row");
    expect(statement.columnText(0)).toBe("hello");
    statement.close();
    database.close();
  });
});
