import { WorkerChannel } from "./channel.mjs";

export type SqlValue = null | number | bigint | string | Uint8Array;
export interface QueryResult {
  columns: string[];
  rows: SqlValue[][];
}

export class ZovaWasmError extends Error {
  constructor(message: string, readonly status: string, readonly statusCode: number) {
    super(message);
    this.name = "ZovaWasmError";
  }
}

function failure(error: unknown): ZovaWasmError {
  if (error instanceof ZovaWasmError) return error;
  const value = error as { message?: unknown; status?: unknown; statusCode?: unknown } | null;
  return new ZovaWasmError(
    String(value?.message ?? error),
    typeof value?.status === "string" ? value.status : "ZOVA_MISUSE",
    typeof value?.statusCode === "number" ? value.statusCode : 16,
  );
}
function invalid(message: string): never {
  throw new ZovaWasmError(message, "ZOVA_INVALID_ARGUMENT", 1);
}
function validateSql(sql: string): void {
  if (typeof sql !== "string" || sql.includes("\0")) invalid("SQL must be a string without NUL bytes");
}
function validateBytes(...values: Uint8Array[]): void {
  if (!values.every(value => value instanceof Uint8Array)) invalid("KV inputs must be Uint8Array values");
}
function validateParameters(parameters: readonly SqlValue[]): void {
  if (!Array.isArray(parameters)) invalid("Parameters must be an array");
  for (const value of parameters) {
    if (value === null || typeof value === "string" || value instanceof Uint8Array) continue;
    if (typeof value === "number" && Number.isFinite(value)) continue;
    if (typeof value === "bigint" && value >= -(1n << 63n) && value < (1n << 63n)) continue;
    invalid("Unsupported SQL parameter or out-of-range integer");
  }
}

const constructionToken = Symbol("Database");

/** Experimental browser database. Each instance owns a dedicated worker. */
export class Database {
  #channel: WorkerChannel;
  #closing?: Promise<void>;

  private constructor(channel: WorkerChannel, token: symbol) {
    if (token !== constructionToken) invalid("Use Database.createMemory() or Database.openPersistent()");
    this.#channel = channel;
  }

  static async createMemory(): Promise<Database> {
    return Database.#open({});
  }

  static async openPersistent(name: string): Promise<Database> {
    if (typeof name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(name)) {
      invalid("Database name must be 1–64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit");
    }
    return Database.#open({ name });
  }

  static async #open(args: { name?: string }): Promise<Database> {
    let channel: WorkerChannel | undefined;
    try {
      channel = new WorkerChannel(new Worker(new URL("./worker.mjs", import.meta.url), { type: "module" }));
      await channel.request("initialize", args);
      return new Database(channel, constructionToken);
    } catch (error) {
      channel?.terminate();
      throw failure(error);
    }
  }

  get closed(): boolean { return this.#channel.closed; }

  async #request<T>(operation: string, prepare: () => object): Promise<T> {
    try {
      if (this.closed) throw new ZovaWasmError("Database is closed", "ZOVA_MISUSE", 16);
      const args = prepare();
      // request posts synchronously before the first await, copying mutable input.
      return await this.#channel.request(operation, args) as T;
    } catch (error) { throw failure(error); }
  }

  exec(sql: string): Promise<void> {
    return this.#request("exec", () => { validateSql(sql); return { sql }; });
  }

  query(sql: string, parameters: readonly SqlValue[] = []): Promise<QueryResult> {
    return this.#request("query", () => {
      validateSql(sql);
      validateParameters(parameters);
      return { sql, parameters: parameters.map(value => value instanceof Uint8Array ? new Uint8Array(value) : value) };
    });
  }

  readonly kv = Object.freeze({
    get: (namespace: Uint8Array, key: Uint8Array): Promise<Uint8Array | null> =>
      this.#request("kv_get", () => {
        validateBytes(namespace, key);
        return { namespace: new Uint8Array(namespace), key: new Uint8Array(key) };
      }),
    put: (namespace: Uint8Array, key: Uint8Array, value: Uint8Array): Promise<void> =>
      this.#request("kv_put", () => {
        validateBytes(namespace, key, value);
        return { namespace: new Uint8Array(namespace), key: new Uint8Array(key), value: new Uint8Array(value) };
      }),
    delete: (namespace: Uint8Array, key: Uint8Array): Promise<boolean> =>
      this.#request("kv_delete", () => {
        validateBytes(namespace, key);
        return { namespace: new Uint8Array(namespace), key: new Uint8Array(key) };
      }),
  });

  close(): Promise<void> {
    if (this.#closing) return this.#closing;
    const closing: Promise<void> = this.#channel.close().then(
      () => undefined,
      (error: unknown) => { throw failure(error); },
    );
    this.#closing = closing;
    return closing;
  }
}
