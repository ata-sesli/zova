import { describe, expect, test } from "bun:test";

import { Database, FreshBuild, ZovaError } from "../js/index.js";

const SCHEMA = `
create table files(id integer primary key, path text not null, size real, body blob);
create index files_path on files(path);
create virtual table bodies using fts5(body);
`;

function count(db: Database, sql: string): bigint {
  const statement = db.prepare(sql);
  try {
    expect(statement.step()).toBe("row");
    return statement.columnInteger(0);
  } finally {
    statement.close();
  }
}

function prepared(): Database {
  const db = Database.createMemory();
  db.exec(SCHEMA);
  db.createVectorCollection("embeddings", { dimensions: 2, metric: "l2", elementType: "f32" });
  return db;
}

function zovaCode(operation: () => unknown): string {
  try {
    operation();
  } catch (error) {
    expect(error).toBeInstanceOf(ZovaError);
    return (error as ZovaError).code;
  }
  throw new Error("expected a ZovaError");
}

describe("fresh builds", () => {
  test("commit every target together", () => {
    const db = prepared();
    const build = db.beginFreshBuild();
    expect(build).toBeInstanceOf(FreshBuild);
    build.tableRows(
      "files",
      ["id", "path", "size", "body"],
      [
        [1n, "a.rs", 1.5, Uint8Array.of(0, 97)],
        [2n, "b.rs", null, Uint8Array.of(98)],
      ],
    );
    build.ftsRows("bodies", ["body"], [["fn main"]]);
    build.graph(
      "code",
      [
        { nodeId: "a.rs", kind: "file", targetType: "none" },
        { nodeId: "b.rs", kind: "file", targetType: "none" },
      ],
      [{ fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1, payload: Uint8Array.of(119) }],
    );
    build.vectors("embeddings", [{ id: "a.rs", values: Float32Array.of(1, 0) }]);
    // The session blocks every other call on the handle, including close.
    expect(() => db.exec("select 1")).toThrow(ZovaError);
    expect(() => db.close()).toThrow(ZovaError);

    const result = build.finish();
    expect(build.closed).toBe(true);
    expect(result.nodeKeys.length).toBe(2);
    expect(result.edgeKeys.length).toBe(1);
    expect(result.profile).toMatchObject({ tableRows: 2, ftsRows: 1, vectorRows: 1, payloadBytes: 1 });

    expect(count(db, "select count(*) from files")).toBe(2n);
    expect(count(db, "select count(*) from bodies where bodies match 'main'")).toBe(1n);
    expect(db.getGraphEdgePayloads("code", result.edgeKeys)).toEqual([Uint8Array.of(119)]);
    expect(db.hasVector("embeddings", "a.rs")).toBe(true);
    expect(zovaCode(() => build.abort())).toBe("ZOVA_MISUSE");
    db.close();
  });

  test("failed, aborted, and closed sessions roll back", () => {
    const db = prepared();

    let build = db.beginFreshBuild();
    build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    expect(zovaCode(() => build.tableRows("files", ["id", "path"], [[2n]]))).toBe(
      "ZOVA_INVALID_ARGUMENT",
    );
    expect(build.closed).toBe(true);
    expect(count(db, "select count(*) from files")).toBe(0n);

    build = db.beginFreshBuild();
    expect(() =>
      build.tableRows("files", ["id", "path"], [[1n, {} as unknown as string]]),
    ).toThrow();
    build.close();

    build = db.beginFreshBuild();
    build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    build.abort();
    expect(count(db, "select count(*) from files")).toBe(0n);

    build = db.beginFreshBuild();
    build.tableRows("files", ["id", "path"], [[1n, "a.rs"]]);
    build.close();
    build.close();
    expect(count(db, "select count(*) from files")).toBe(0n);
    expect(zovaCode(() => build.finish())).toBe("ZOVA_MISUSE");

    // A native failure also ends the session.
    build = db.beginFreshBuild();
    expect(() => build.tableRows("missing_table", ["id"], [[1n]])).toThrow(ZovaError);
    expect(() => build.finish()).toThrow(ZovaError);
    build.close();
    db.exec("select 1");
    db.close();
  });
});
