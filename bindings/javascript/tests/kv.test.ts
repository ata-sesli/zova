import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { AsyncDatabase, Database, type KvEntry } from "../js/index.js";

const temporaryDirectories: string[] = [];

function temporaryDatabasePath(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-kv-"));
  temporaryDirectories.push(directory);
  return join(directory, "test.zova");
}

function bytes(value: string | number[]): Uint8Array {
  if (typeof value === "string") {
    return new TextEncoder().encode(value);
  }
  return new Uint8Array(value);
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("Database key-value storage", () => {
  test("crud preserves exact bytes", () => {
    const database = Database.create(temporaryDatabasePath());
    try {
      database.kvPut(bytes("settings"), bytes("theme"), bytes("dark"));
      database.kvPut(bytes("settings"), bytes("retries"), bytes([0, 1, 2]));
      database.kvPut(bytes("settings"), bytes("empty"), new Uint8Array(0));

      expect(database.kvGet(bytes("settings"), bytes("theme"))).toEqual(bytes("dark"));
      expect(database.kvGet(bytes("settings"), bytes("retries"))).toEqual(
        bytes([0, 1, 2]),
      );
      expect(database.kvGet(bytes("settings"), bytes("empty"))).toEqual(
        new Uint8Array(0),
      );
      expect(database.kvGet(bytes("settings"), bytes("ghost"))).toBeNull();
      expect(database.kvGet(bytes("other"), bytes("theme"))).toBeNull();

      expect(database.kvCount(bytes("settings"))).toBe(3n);

      database.kvPut(bytes("settings"), bytes("theme"), bytes("light"));
      expect(database.kvGet(bytes("settings"), bytes("theme"))).toEqual(bytes("light"));
      expect(database.kvCount(bytes("settings"))).toBe(3n);

      database.kvDelete(bytes("settings"), bytes("theme"));
      expect(database.kvGet(bytes("settings"), bytes("theme"))).toBeNull();
      expect(database.kvCount(bytes("settings"))).toBe(2n);

      database.kvDelete(bytes("settings"), bytes("ghost"));
      expect(database.kvCount(bytes("settings"))).toBe(2n);

      database.kvClearNamespace(bytes("settings"));
      expect(database.kvCount(bytes("settings"))).toBe(0n);
    } finally {
      database.close();
    }
  });

  test("get many preserves order and duplicates", () => {
    const database = Database.create(temporaryDatabasePath());
    try {
      database.kvPut(bytes("ns"), bytes("a"), bytes("1"));
      database.kvPut(bytes("ns"), bytes("b"), bytes("2"));
      database.kvPut(bytes("ns"), bytes("c"), bytes("3"));

      const results = database.kvGetMany(bytes("ns"), [
        bytes("c"),
        bytes("ghost"),
        bytes("a"),
        bytes("c"),
      ]);
      expect(results.length).toBe(4);
      expect(results[0]).toEqual(bytes("3"));
      expect(results[1]).toBeNull();
      expect(results[2]).toEqual(bytes("1"));
      expect(results[3]).toEqual(bytes("3"));
    } finally {
      database.close();
    }
  });

  test("put many is atomic and delete many ignores missing", () => {
    const database = Database.create(temporaryDatabasePath());
    try {
      const entries: KvEntry[] = [
        { key: bytes("k1"), value: bytes("v1") },
        { key: bytes("k2"), value: bytes("v2") },
        { key: bytes("k3"), value: new Uint8Array(0) },
      ];
      database.kvPutMany(bytes("ns"), entries);
      expect(database.kvCount(bytes("ns"))).toBe(3n);

      database.kvDeleteMany(bytes("ns"), [bytes("k1"), bytes("ghost"), bytes("k3")]);
      expect(database.kvCount(bytes("ns"))).toBe(1n);
      expect(database.kvGet(bytes("ns"), bytes("k2"))).toEqual(bytes("v2"));

      database.kvPutMany(bytes("ns"), []);
      database.kvDeleteMany(bytes("ns"), []);
      expect(database.kvCount(bytes("ns"))).toBe(1n);
    } finally {
      database.close();
    }
  });

  test("partitions by namespace", () => {
    const database = Database.create(temporaryDatabasePath());
    try {
      database.kvPut(bytes("a"), bytes("key"), bytes("1"));
      database.kvPut(bytes("b"), bytes("key"), bytes("2"));

      expect(database.kvGet(bytes("a"), bytes("key"))).toEqual(bytes("1"));
      expect(database.kvGet(bytes("b"), bytes("key"))).toEqual(bytes("2"));
      expect(database.kvCount(bytes("a"))).toBe(1n);
      expect(database.kvCount(bytes("b"))).toBe(1n);

      database.kvClearNamespace(bytes("a"));
      expect(database.kvCount(bytes("a"))).toBe(0n);
      expect(database.kvCount(bytes("b"))).toBe(1n);
    } finally {
      database.close();
    }
  });
});

describe("AsyncDatabase key-value storage", () => {
  test("async crud and many", async () => {
    const database = AsyncDatabase.create(temporaryDatabasePath());

    await database.kvPut(bytes("cfg"), bytes("mode"), bytes("fast"));
    await database.kvPut(bytes("cfg"), bytes("limit"), bytes("10"));

    expect(await database.kvGet(bytes("cfg"), bytes("mode"))).toEqual(bytes("fast"));
    expect(await database.kvGet(bytes("cfg"), bytes("nope"))).toBeNull();
    expect(await database.kvCount(bytes("cfg"))).toBe(2n);

    const results = await database.kvGetMany(bytes("cfg"), [
      bytes("mode"),
      bytes("nope"),
      bytes("limit"),
    ]);
    expect(results.length).toBe(3);
    expect(results[0]).toEqual(bytes("fast"));
    expect(results[1]).toBeNull();
    expect(results[2]).toEqual(bytes("10"));

    const entries: KvEntry[] = [
      { key: bytes("x"), value: bytes("1") },
      { key: bytes("y"), value: bytes("2") },
    ];
    await database.kvPutMany(bytes("cfg"), entries);
    expect(await database.kvCount(bytes("cfg"))).toBe(4n);

    await database.kvDeleteMany(bytes("cfg"), [bytes("x"), bytes("nope"), bytes("y")]);
    expect(await database.kvCount(bytes("cfg"))).toBe(2n);

    await database.kvClearNamespace(bytes("cfg"));
    expect(await database.kvCount(bytes("cfg"))).toBe(0n);

    await database.close();
  });
});