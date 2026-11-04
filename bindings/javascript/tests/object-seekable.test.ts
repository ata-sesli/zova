import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { AsyncDatabase, Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

function databasePath(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-seekable-"));
  temporaryDirectories.push(directory);
  return join(directory, "seekable.zova");
}

function deterministicBytes(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = (index * 31 + index / 7 + 17) & 0xff;
  }
  return bytes;
}

function expectStatus(operation: () => unknown, code: string): void {
  try {
    operation();
  } catch (error) {
    expect(error).toBeInstanceOf(ZovaError);
    expect((error as ZovaError).code).toBe(code);
    return;
  }
  throw new Error(`expected ${code}`);
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("object seekable reader", () => {
  test("reads sequentially and seeks to the start, middle, end and past the end", () => {
    const db = Database.create(databasePath());
    const bytes = deterministicBytes((2 << 20) + 4321);
    const id = db.putObjectWithOptions(bytes, { profile: "streaming" });
    const reader = db.objectSeekableReader(id);
    expect(reader.size).toBe(BigInt(bytes.length));

    const chunks: Uint8Array[] = [];
    for (;;) {
      const chunk = reader.read(32 * 1024);
      if (chunk.length === 0) break;
      chunks.push(chunk);
    }
    expect(Buffer.concat(chunks)).toEqual(Buffer.from(bytes));
    expect(reader.position).toBe(BigInt(bytes.length));

    expect(reader.seek(0)).toBe(0n);
    expect(reader.read(5)).toEqual(bytes.slice(0, 5));

    const middle = (1 << 20) - 3;
    expect(reader.seek(BigInt(middle))).toBe(BigInt(middle));
    expect(reader.read(6)).toEqual(bytes.slice(middle, middle + 6));
    expect(reader.seek(-4, "current")).toBe(BigInt(middle + 2));
    expect(reader.read(2)).toEqual(bytes.slice(middle + 2, middle + 4));

    expect(reader.seek(-10, "end")).toBe(BigInt(bytes.length - 10));
    expect(reader.read(100)).toEqual(bytes.slice(bytes.length - 10));
    expect(reader.read(1)).toEqual(new Uint8Array());

    reader.seek(bytes.length + 5);
    expect(reader.read(4)).toEqual(new Uint8Array());
    expectStatus(() => reader.seek(-1), "ZOVA_INVALID_ARGUMENT");

    expectStatus(() => db.close(), "ZOVA_MISUSE");
    reader.close();
    reader.close();
    expect(reader.closed).toBe(true);
    expectStatus(() => reader.read(1), "ZOVA_MISUSE");
    db.close();
  });

  test("reports an object deleted while it is being read", () => {
    const db = Database.create(databasePath());
    const bytes = deterministicBytes((2 << 20) + 9);
    const id = db.putObjectWithOptions(bytes, { profile: "streaming" });
    const reader = db.objectSeekableReader(id);
    expect(reader.read(16)).toEqual(bytes.slice(0, 16));

    db.deleteObject(id);
    // Bytes of the already verified chunk stay readable.
    expect(reader.read(16)).toEqual(bytes.slice(16, 32));
    reader.seek(1 << 20);
    expectStatus(() => reader.read(16), "ZOVA_OBJECT_NOT_FOUND");
    reader.close();
    db.close();
  });

  test("reads and seeks asynchronously in call order", async () => {
    const db = await AsyncDatabase.create(databasePath());
    const bytes = deterministicBytes(300_000);
    const id = await db.putObject(bytes);
    const reader = await db.objectSeekableReader(id);
    expect(reader.size).toBe(BigInt(bytes.length));

    const [first, , second] = await Promise.all([
      reader.readAsync(10),
      reader.seekAsync(200_000),
      reader.readAsync(10),
    ]);
    expect(first).toEqual(bytes.slice(0, 10));
    expect(second).toEqual(bytes.slice(200_000, 200_010));

    expect(await reader.seekAsync(-3, "end")).toBe(BigInt(bytes.length - 3));
    expect(await reader.readAsync(10)).toEqual(bytes.slice(bytes.length - 3));
    expect(await reader.readAsync(10)).toEqual(new Uint8Array());

    reader.close();
    await expect(reader.readAsync(1)).rejects.toBeInstanceOf(ZovaError);
    await db.close();
  });
});
