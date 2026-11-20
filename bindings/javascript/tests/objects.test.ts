import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  AsyncDatabase,
  Database,
  objectChunkId,
  objectId,
  objectIdFromHex,
  objectIdToHex,
  ZovaError,
} from "../js/index.js";

const temporaryDirectories: string[] = [];

function database(): Database {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-objects-"));
  temporaryDirectories.push(directory);
  return Database.create(join(directory, "objects.zova"));
}

function deterministicBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (index * 31 + 17) & 0xff;
  }
  return bytes;
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("objects", () => {
  test("stores, ranges, manifests, chunks, and deletes content-addressed data", () => {
    const db = database();
    const bytes = deterministicBytes(160_000);

    const id = db.putObject(bytes);
    expect(id).toEqual(objectId(bytes));
    expect(id.byteLength).toBe(32);
    expect(db.hasObject(id)).toBe(true);
    expect(db.objectSize(id)).toBe(160_000n);
    expect(db.objectChunkCount(id)).toBeGreaterThan(1n);
    expect(db.getObject(id)).toEqual(bytes);
    expect(db.readObjectRange(id, 65_000n, 4096)).toEqual(
      bytes.slice(65_000, 69_096),
    );

    const manifest = db.objectManifest(id);
    expect(manifest.objectId).toEqual(id);
    expect(manifest.sizeBytes).toBe(160_000n);
    expect(manifest.chunkCount).toBe(BigInt(manifest.chunks.length));
    expect(manifest.chunks[0]?.index).toBe(0n);
    const firstChunk = manifest.chunks[0];
    if (firstChunk === undefined) {
      throw new Error("object manifest had no chunks");
    }
    const chunk = db.getObjectChunk(firstChunk.hash);
    expect(objectChunkId(chunk)).toEqual(firstChunk.hash);
    expect(db.hasObjectChunk(firstChunk.hash)).toBe(true);

    const hex = objectIdToHex(id);
    expect(hex).toHaveLength(64);
    expect(objectIdFromHex(hex)).toEqual(id);

    db.deleteObject(id);
    expect(db.hasObject(id)).toBe(false);
    db.close();
  });

  test("streaming writer finishes, cancels, and closes idempotently", () => {
    const db = database();
    const first = deterministicBytes(70_000);
    const second = deterministicBytes(90_000);
    const expected = new Uint8Array(first.length + second.length);
    expected.set(first);
    expected.set(second, first.length);

    const writer = db.objectWriter();
    writer.write(first);
    writer.write(second);
    const id = writer.finish();
    expect(db.getObject(id)).toEqual(expected);
    expect(() => writer.write(first)).toThrow(ZovaError);
    writer.close();

    const cancelled = db.objectWriter();
    cancelled.write(first);
    cancelled.cancel();
    cancelled.close();

    db.close();
  });

  test("profile-aware APIs and sequential readers preserve object identity", () => {
    const db = database();
    const bytes = deterministicBytes(180_000);
    const options = { profile: "deduplication" } as const;

    const id = db.putObjectWithOptions(bytes, options);
    expect(id).toEqual(objectId(bytes));

    const reader = db.objectReader(id);
    expect(reader.read(7)).toEqual(bytes.slice(0, 7));
    expect(reader.read(1_000_000)).toEqual(bytes.slice(7));
    expect(reader.read(1)).toEqual(new Uint8Array());
    reader.close();
    reader.close();
    expect(() => reader.read(1)).toThrow(ZovaError);

    const writer = db.objectWriterWithOptions(options);
    writer.write(bytes);
    expect(writer.finish()).toEqual(id);

    const chunk = deterministicBytes(32_000);
    const hash = objectChunkId(chunk);
    db.putObjectChunkWithOptions(hash, chunk, options);
    const assembledId = objectId(chunk);
    db.assembleObjectFromChunksWithOptions(
      assembledId,
      BigInt(chunk.length),
      [{ index: 0n, hash, offset: 0n, sizeBytes: BigInt(chunk.length) }],
      options,
    );
    expect(db.getObject(assembledId)).toEqual(chunk);

    expect(() =>
      db.putObjectWithOptions(bytes, { profile: "unknown" as never }),
    ).toThrow(ZovaError);
    db.close();
  });

  test("object reader participates in native child-handle lifetime", () => {
    const db = database();
    const bytes = deterministicBytes(2048);
    const id = db.putObject(bytes);
    const reader = db.objectReader(id);
    expect(() => db.close()).toThrow(ZovaError);
    expect(reader.read(2048)).toEqual(bytes);
    reader.close();
    db.close();
  });

  test("main-store object mutation commits and rolls back with a caller transaction", () => {
    const db = database();
    const bytes = deterministicBytes(100_000);
    const id = objectId(bytes);
    db.exec("CREATE TABLE notes(body TEXT, object_id BLOB)");

    // The object and the row referencing it commit together.
    db.transaction((transaction) => {
      transaction.putObject(bytes);
      const insert = transaction.prepare("INSERT INTO notes(body, object_id) VALUES (?, ?)");
      insert.bindText(1, "committed");
      insert.bindBlob(2, id);
      expect(insert.step()).toBe("done");
      insert.close();
    });
    expect(db.hasObject(id)).toBe(true);
    const committed = db.prepare("SELECT count(*) FROM notes");
    expect(committed.step()).toBe("row");
    expect(committed.columnInteger(0)).toBe(1n);
    committed.close();

    // A caller rollback removes the object and the referencing row together.
    const discarded = deterministicBytes(99_001);
    const discardedId = objectId(discarded);
    expect(() =>
      db.transaction((transaction) => {
        transaction.exec("INSERT INTO notes(body) VALUES ('rolled back')");
        transaction.putObject(discarded);
        throw new Error("abort the caller transaction");
      }),
    ).toThrow("abort the caller transaction");
    expect(db.hasObject(discardedId)).toBe(false);
    const count = db.prepare("SELECT count(*) FROM notes WHERE body = 'rolled back'");
    expect(count.step()).toBe("row");
    expect(count.columnInteger(0)).toBe(0n);
    count.close();

    db.close();
  });

  test("main-store object writer still rejects an active transaction", () => {
    const db = database();
    const bytes = deterministicBytes(100_000);
    db.exec("CREATE TABLE notes(body TEXT)");

    expect(() =>
      db.transaction((transaction) => {
        transaction.exec("INSERT INTO notes VALUES ('held')");
        transaction.objectWriter();
      }),
    ).toThrow(ZovaError);
    const count = db.prepare("SELECT count(*) FROM notes");
    expect(count.step()).toBe("row");
    expect(count.columnInteger(0)).toBe(0n);
    count.close();

    // A synchronous put inside the same shape of transaction still commits.
    db.transaction((transaction) => {
      transaction.putObject(bytes);
    });
    expect(db.hasObject(objectId(bytes))).toBe(true);

    db.close();
  });

  test("object IDs reject non-32-byte inputs", () => {
    const db = database();
    expect(() => db.getObject(new Uint8Array(31))).toThrow(ZovaError);
    expect(() => objectIdFromHex("00")).toThrow(ZovaError);
    db.close();
  });

  test("stores lz4-compressed chunks only after opting in and reads them back", async () => {
    const text = new TextEncoder().encode(
      Array.from({ length: 60_000 }, (_, line) => `${line}: compressible object line\n`).join(""),
    );
    const encodedChunks = (db: Database): bigint => {
      const statement = db.prepare("SELECT count(*) FROM _zova_chunks WHERE encoding = 1");
      expect(statement.step()).toBe("row");
      const count = statement.columnInteger(0);
      statement.close();
      return BigInt(count);
    };

    const db = database();
    expect(() => db.setObjectCompression("zstd" as never)).toThrow(ZovaError);
    const plainId = db.putObject(text);
    expect(encodedChunks(db)).toBe(0n);
    db.deleteObject(plainId);

    db.setObjectCompression("lz4");
    for (const profile of ["deduplication", "streaming"] as const) {
      const id = db.putObjectWithOptions(text, { profile });
      expect(objectIdToHex(id)).toBe(objectIdToHex(objectId(text)));
      expect(encodedChunks(db)).toBeGreaterThan(0n);
      expect(db.getObject(id)).toEqual(text);
      expect(db.readObjectRange(id, 1_000_000n, 70_000)).toEqual(text.subarray(1_000_000, 1_070_000));
      db.deleteObject(id);
    }
    db.setObjectCompression("none");
    db.close();

    const directory = mkdtempSync(join(tmpdir(), "zova-javascript-objects-"));
    temporaryDirectories.push(directory);
    const asyncDb = AsyncDatabase.create(join(directory, "async.zova"));
    await expect(asyncDb.setObjectCompression("zstd" as never)).rejects.toBeInstanceOf(ZovaError);
    await asyncDb.setObjectCompression("lz4");
    const asyncId = await asyncDb.putObject(text);
    expect(await asyncDb.getObject(asyncId)).toEqual(text);
    await asyncDb.close();
    const reopened = Database.open(join(directory, "async.zova"));
    expect(encodedChunks(reopened)).toBeGreaterThan(0n);
    reopened.close();
  });
});
