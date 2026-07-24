import native = require("../index.js");

import { normalizeNativeError, ZovaError } from "./errors.js";
import type {
  GraphEdgeInput,
  GraphNodeInput,
  GraphWalkItem,
  GraphWalkOptions,
} from "./graph.js";
import type { OpenOptions } from "./types.js";
import type {
  VectorInput,
  VectorSearchOptions,
  VectorSearchResult,
  VectorValues,
} from "./vector.js";

export class AsyncDatabase {
  readonly #native: native.NativeDatabase;
  #tail: Promise<void> = Promise.resolve();
  #closing = false;
  #closed = false;
  #closePromise: Promise<void> | undefined;

  private constructor(database: native.NativeDatabase) {
    this.#native = database;
  }

  static create(path: string): AsyncDatabase {
    return new AsyncDatabase(native.NativeDatabase.create(path));
  }

  static open(path: string, options: OpenOptions = {}): AsyncDatabase {
    return new AsyncDatabase(
      native.NativeDatabase.open(path, {
        readOnly: options.readOnly,
        busyTimeoutMs: options.busyTimeoutMs,
      }),
    );
  }

  static restoreBackup(
    source: string,
    destination: string,
    verify = true,
  ): Promise<void> {
    return native
      .asyncRestoreBackup(source, destination, verify)
      .catch((error: unknown) => {
        throw normalizeNativeError(error);
      });
  }

  get closed(): boolean {
    return this.#closed;
  }

  #enqueue<T>(operation: () => Promise<T>): Promise<T> {
    if (this.#closing) {
      return Promise.reject(
        new ZovaError(
          "ZOVA_MISUSE",
          16,
          "asynchronous database is closing or closed",
        ),
      );
    }
    const result = this.#tail.then(operation).catch((error) => {
      throw normalizeNativeError(error);
    });
    this.#tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  exec(sql: string): Promise<void> {
    return this.#enqueue(() => this.#native.asyncExec(sql));
  }

  backupTo(destination: string, verify = true): Promise<void> {
    return this.#enqueue(() =>
      this.#native.asyncBackupTo(destination, verify),
    );
  }

  compactTo(destination: string, verify = true): Promise<void> {
    return this.#enqueue(() =>
      this.#native.asyncCompactTo(destination, verify),
    );
  }

  putObject(data: Uint8Array): Promise<Uint8Array> {
    return this.#enqueue(() => this.#native.asyncPutObject(data));
  }

  getObject(id: Uint8Array): Promise<Uint8Array> {
    return this.#enqueue(() => this.#native.asyncGetObject(id));
  }

  putVectors(
    collectionName: string,
    vectors: readonly VectorInput[],
  ): Promise<void> {
    return this.#enqueue(() =>
      this.#native.asyncPutVectors(collectionName, [...vectors]),
    );
  }

  searchVectors(
    collectionName: string,
    query: VectorValues,
    options: VectorSearchOptions,
  ): Promise<VectorSearchResult[]> {
    return this.#enqueue(() =>
      this.#native.asyncSearchVectors(
        collectionName,
        query,
        options.candidateIds === undefined
          ? undefined
          : [...options.candidateIds],
        options.maxDistance,
        options.limit,
      ),
    );
  }

  putGraphNodes(inputs: readonly GraphNodeInput[]): Promise<void> {
    return this.#enqueue(() =>
      this.#native.asyncPutGraphNodes([...inputs]),
    );
  }

  putGraphEdges(inputs: readonly GraphEdgeInput[]): Promise<void> {
    return this.#enqueue(() =>
      this.#native.asyncPutGraphEdges([...inputs]),
    );
  }

  graphWalk(options: GraphWalkOptions): Promise<GraphWalkItem[]> {
    return this.#enqueue(() => this.#native.asyncGraphWalk(options));
  }

  close(): Promise<void> {
    if (this.#closePromise !== undefined) {
      return this.#closePromise;
    }
    this.#closing = true;
    this.#closePromise = this.#tail
      .then(() => this.#native.close())
      .catch((error) => {
        throw normalizeNativeError(error);
      })
      .finally(() => {
        this.#closed = true;
      });
    return this.#closePromise;
  }
}
