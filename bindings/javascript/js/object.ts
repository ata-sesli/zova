import native = require("../index.js");

import { callNative, invalidArgument } from "./errors.js";

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
