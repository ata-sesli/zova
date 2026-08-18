import native = require("../index.js");

import { normalizeNativeError, ZovaError } from "./errors.js";
import type {
  GraphEdgeInput,
  GraphNodeInput,
  GraphWalkItem,
  GraphWalkOptions,
} from "./graph.js";
import type { OpenOptions } from "./types.js";
import type { KvEntry } from "./types.js";
import { Subscription } from "./subscription.js";
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

  static createMemory(): AsyncDatabase {
    return new AsyncDatabase(native.NativeDatabase.createMemory());
  }

  static open(path: string, options: OpenOptions = {}): AsyncDatabase {
    return new AsyncDatabase(
      native.NativeDatabase.open(path, {
        readOnly: options.readOnly,
        busyTimeoutMs: options.busyTimeoutMs,
      }),
    );
  }

  static restoreBackupToMemory(source: string, verify = true): Promise<AsyncDatabase> {
    return native
      .asyncRestoreBackupToMemory(source, verify)
      .then((database: native.NativeDatabase) => new AsyncDatabase(database))
      .catch((error: unknown) => {
        throw normalizeNativeError(error);
      });
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

  kvGet(namespace: Uint8Array, key: Uint8Array): Promise<Uint8Array | null> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvGet(namespace, key);
      if (result.kind !== "get") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv get result kind",
        );
      }
      return result.value ?? null;
    });
  }

  kvGetMany(
    namespace: Uint8Array,
    keys: readonly Uint8Array[],
  ): Promise<(Uint8Array | null)[]> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvGetMany(namespace, [...keys]);
      if (result.kind !== "many") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv get many result kind",
        );
      }
      return (result.values ?? []).map((value) => value ?? null);
    });
  }

  kvPut(namespace: Uint8Array, key: Uint8Array, value: Uint8Array): Promise<void> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvPut(namespace, key, value);
      if (result.kind !== "void") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv put result kind",
        );
      }
    });
  }

  kvPutMany(
    namespace: Uint8Array,
    entries: readonly KvEntry[],
  ): Promise<void> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvPutMany(
        namespace,
        entries.map((entry) => ({
          key: entry.key,
          value: entry.value,
        })),
      );
      if (result.kind !== "void") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv put many result kind",
        );
      }
    });
  }

  kvDelete(namespace: Uint8Array, key: Uint8Array): Promise<void> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvDelete(namespace, key);
      if (result.kind !== "void") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv delete result kind",
        );
      }
    });
  }

  kvDeleteMany(namespace: Uint8Array, keys: readonly Uint8Array[]): Promise<void> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvDeleteMany(namespace, [...keys]);
      if (result.kind !== "void") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv delete many result kind",
        );
      }
    });
  }

  kvCount(namespace: Uint8Array): Promise<bigint> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvCount(namespace);
      if (result.kind !== "count" || result.count === undefined) {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv count result kind",
        );
      }
      return result.count;
    });
  }

  kvClearNamespace(namespace: Uint8Array): Promise<void> {
    return this.#enqueue(async () => {
      const result = await this.#native.asyncKvClearNamespace(namespace);
      if (result.kind !== "void") {
        throw new ZovaError(
          "ZOVA_MISUSE",
          16,
          "unexpected kv clear namespace result kind",
        );
      }
    });
  }

  async listen(channel: string): Promise<Subscription> {
    const native = await this.#enqueue(() => this.#native.asyncListen(channel));
    return Subscription.create(native);
  }

  notify(channel: string, payload: string): Promise<void> {
    return this.#enqueue(() => this.#native.asyncNotify(channel, payload));
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
      .then(() => {
        this.#closed = true;
      })
      .catch((error) => {
        this.#closing = false;
        this.#closePromise = undefined;
        throw normalizeNativeError(error);
      });
    return this.#closePromise;
  }
}
