import { describe, expect, test } from "bun:test";

import { Database, ZovaError } from "../js/index.js";
import type { SqlValue } from "../js/index.js";

function scalar(db: Database, sql: string): SqlValue {
  const statement = db.prepare(sql);
  try {
    expect(statement.step()).toBe("row");
    switch (statement.columnType(0)) {
      case "integer":
        return statement.columnInteger(0);
      case "float":
        return statement.columnFloat(0);
      case "text":
        return statement.columnText(0);
      case "blob":
        return statement.columnBlob(0);
      default:
        return null;
    }
  } finally {
    statement.close();
  }
}

describe("SQL functions", () => {
  test("receive and return every SQL type", () => {
    const seen: SqlValue[][] = [];
    const db = Database.createMemory();
    db.registerFunction("echo", -1, (...args) => {
      seen.push(args);
      return args[0];
    }, { deterministic: true });
    db.registerFunction("plus", 2, (a, b) => (a as bigint) + (b as bigint), { innocuous: true });
    db.registerFunction("flag", 0, () => true, { directOnly: true });
    db.registerFunction("half", 1, (a) => Number(a) / 2);
    db.registerFunction("empty_value", 0, () => undefined);

    expect(scalar(db, "select echo(42, 1.5, 'text', x'0001', null)")).toBe(42n);
    expect(seen.at(-1)).toEqual([42n, 1.5, "text", Uint8Array.of(0, 1), null]);
    expect(scalar(db, "select echo('héllo')")).toBe("héllo");
    expect(scalar(db, "select echo(x'ff')")).toEqual(Uint8Array.of(255));
    expect(scalar(db, "select echo(null)")).toBeNull();
    expect(scalar(db, "select plus(2, 3)")).toBe(5n);
    expect(scalar(db, "select flag()")).toBe(1n);
    expect(scalar(db, "select half(3)")).toBe(1.5);
    // A number is always a SQL float.
    expect(scalar(db, "select typeof(half(4))")).toBe("real");
    expect(scalar(db, "select empty_value()")).toBeNull();

    // The function runs once per row.
    db.exec("create table t(x integer); insert into t values (1), (2), (3);");
    expect(scalar(db, "select sum(plus(x, 10)) from t")).toBe(36n);
    db.close();
  });

  test("exceptions and unsupported results fail the statement", () => {
    const db = Database.createMemory();
    db.registerFunction("boom", 0, () => {
      throw new RangeError("no luck");
    });
    db.registerFunction("weird", 0, () => ({}) as unknown as null);
    db.registerFunction("huge", 0, () => 1n << 70n);
    for (const [sql, message] of [
      ["select boom()", "RangeError: no luck"],
      ["select weird()", "unsupported SQL function result type Object"],
      ["select huge()", "outside the signed 64-bit range"],
    ]) {
      expect(() => scalar(db, sql)).toThrow(message);
    }
    // The connection stays usable.
    expect(scalar(db, "select 1")).toBe(1n);
    db.close();
  });

  test("rejects invalid registrations", () => {
    const db = Database.createMemory();
    for (const [name, arity] of [["", 0], ["ok", 200], ["bad name", 0]] as const) {
      expect(() => db.registerFunction(name, arity, () => 1n)).toThrow(ZovaError);
    }
    db.registerFunction("once", 0, () => 1n);
    expect(() => db.registerFunction("once", 0, () => 2n)).toThrow(ZovaError);
    expect(scalar(db, "select once()")).toBe(1n);
    db.close();
  });
});
