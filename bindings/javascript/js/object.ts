import native = require("../index.js");

import { callNative, invalidArgument, normalizeNativeError } from "./errors.js";

export interface ObjectManifestChunk {
  readonly index: bigint;
  readonly hash: Uint8Array;
  readonly offset: bigint;
  readonly sizeBytes: bigint;
}

export interface ObjectManifest {
  readonly objectId: Uint8Array;
  readonly sizeBytes: bigint;
  readonly chunkCount: bigint;
  readonly chunker: string;
  readonly chunks: readonly ObjectManifestChunk[];
}

export interface ObjectManifestChunkInput {
  readonly index: bigint;
  readonly hash: Uint8Array;
  readonly offset: bigint;
  readonly sizeBytes: bigint;
}

export type ObjectStorageProfile = "deduplication" | "streaming";

export interface ObjectPutOptions {
  readonly profile: ObjectStorageProfile;
}

export function objectId(data: Uint8Array): Uint8Array {
  return callNative(() => native.objectId(data));
}

export function objectChunkId(data: Uint8Array): Uint8Array {
  return callNative(() => native.objectChunkId(data));
}

export function objectIdToHex(id: Uint8Array): string {
  if (id.byteLength !== 32) {
    throw invalidArgument("object id must contain exactly 32 bytes");
  }
  return Array.from(id, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function objectIdFromHex(value: string): Uint8Array {
  if (!/^[0-9a-fA-F]{64}$/.test(value)) {
    throw invalidArgument("object id hex must contain exactly 64 hexadecimal characters");
  }
  const bytes = new Uint8Array(32);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

export class ObjectWriter {
  readonly #native: native.NativeObjectWriter;

  constructor(writer: native.NativeObjectWriter) {
    this.#native = writer;
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  write(data: Uint8Array): void {
    callNative(() => this.#native.write(data));
  }

  finish(): Uint8Array {
    return callNative(() => this.#native.finish());
  }

  cancel(): void {
    callNative(() => this.#native.cancel());
  }

  close(): void {
    callNative(() => this.#native.close());
  }
}

/** Origin for `ObjectSeekableReader.seek`, as in `fs` and `io.Seeker`. */
export type SeekWhence = "start" | "current" | "end";

/**
 * Seekable, verified reader for one stored object, for HTTP range serving.
 *
 * Each chunk is checked against its manifest SHA-256 once, into a per-reader
 * buffer, before any of its bytes are returned; the whole-object hash is not
 * checked. The reader holds no read transaction between calls, so other
 * connections can commit while it stays open. A read that needs a new chunk
 * of an object deleted since opening fails with `ZOVA_OBJECT_NOT_FOUND`.
 * Reads return an empty array at or past the end. Asynchronous reads and
 * seeks run in call order.
 */
export class ObjectSeekableReader {
  readonly #native: native.NativeObjectSeekableReader;
  #tail: Promise<void> = Promise.resolve();

  constructor(reader: native.NativeObjectSeekableReader) {
    this.#native = reader;
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  /** Object size in bytes. */
  get size(): bigint {
    return this.#native.size;
  }

  /** Offset of the next read. */
  get position(): bigint {
    return callNative(() => this.#native.position);
  }

  read(size: number): Uint8Array {
    checkReadSize(size);
    return callNative(() => this.#native.read(size));
  }

  /** Move the read offset and return the new absolute offset. */
  seek(offset: bigint | number, whence: SeekWhence = "start"): bigint {
    const target = this.#target(offset, whence);
    return callNative(() => this.#native.seek(target));
  }

  readAsync(size: number): Promise<Uint8Array> {
    checkReadSize(size);
    return this.#enqueue(() => this.#native.asyncRead(size));
  }

  seekAsync(offset: bigint | number, whence: SeekWhence = "start"): Promise<bigint> {
    return this.#enqueue(async () => this.seek(offset, whence));
  }

  close(): void {
    callNative(() => this.#native.close());
  }

  #target(offset: bigint | number, whence: SeekWhence): bigint {
    if (typeof offset === "number" && !Number.isSafeInteger(offset)) {
      throw invalidArgument("object reader offset must be a safe integer or bigint");
    }
    const delta = BigInt(offset);
    let base: bigint;
    switch (whence) {
      case "start":
        base = 0n;
        break;
      case "current":
        base = this.position;
        break;
      case "end":
        base = this.size;
        break;
      default:
        throw invalidArgument(`unsupported seek origin: ${String(whence)}`);
    }
    const target = base + delta;
    if (target < 0n) {
      throw invalidArgument("object reader offset must not be negative");
    }
    return target;
  }

  #enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.#tail.then(operation).catch((error) => {
      throw normalizeNativeError(error);
    });
    this.#tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }
}

function checkReadSize(size: number): void {
  if (!Number.isInteger(size) || size < 0 || size > 0xffff_ffff) {
    throw invalidArgument("object reader size must be a non-negative 32-bit integer");
  }
}

export class ObjectReader {
  readonly #native: native.NativeObjectReader;

  constructor(reader: native.NativeObjectReader) {
    this.#native = reader;
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  read(size: number): Uint8Array {
    if (!Number.isInteger(size) || size < 0 || size > 0xffff_ffff) {
      throw invalidArgument("object reader size must be a non-negative 32-bit integer");
    }
    return callNative(() => this.#native.read(size));
  }

  close(): void {
    callNative(() => this.#native.close());
  }
}
