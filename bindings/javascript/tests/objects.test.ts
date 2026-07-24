import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
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

  test("main-store object mutation preserves active-transaction rejection", () => {
    const db = database();
    const bytes = deterministicBytes(100_000);
    const id = objectId(bytes);
    db.exec("CREATE TABLE notes(body TEXT)");

    expect(() =>
      db.transaction((transaction) => {
        transaction.exec("INSERT INTO notes VALUES ('rolled back')");
        transaction.putObject(bytes);
      }),
    ).toThrow(ZovaError);
    expect(db.hasObject(id)).toBe(false);
    const count = db.prepare("SELECT count(*) FROM notes");
    expect(count.step()).toBe("row");
    expect(count.columnInteger(0)).toBe(0n);
    count.close();

    db.close();
  });

  test("object IDs reject non-32-byte inputs", () => {
    const db = database();
    expect(() => db.getObject(new Uint8Array(31))).toThrow(ZovaError);
    expect(() => objectIdFromHex("00")).toThrow(ZovaError);
    db.close();
  });
});
