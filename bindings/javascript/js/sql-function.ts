import type native = require("../index.js");

/** One SQL value: integers are `bigint` and floats are `number`. */
export type SqlValue = null | bigint | number | string | Uint8Array;

/**
 * What a SQL function may return. A `number` becomes a SQL float, a `bigint`
 * an integer, a `boolean` the integer 0 or 1, and `null` or `undefined` NULL.
 */
export type SqlFunctionResult = SqlValue | boolean | undefined;

export type SqlFunction = (...args: SqlValue[]) => SqlFunctionResult;

export interface SqlFunctionOptions {
  /** Same arguments always give the same result, so SQLite may reuse it. */
  readonly deterministic?: boolean;
  /** Callable only from top-level SQL, not from views, triggers, or schema. */
  readonly directOnly?: boolean;
  /** Has no side effects and leaks no information. */
  readonly innocuous?: boolean;
}

/**
 * Wrap a user function so it never throws into native code: exceptions and
 * unsupported results become SQL errors.
 */
export function sqlFunctionTrampoline(
  fn: SqlFunction,
): (args: SqlValue[]) => native.NativeSqlFunctionResult {
  return (args) => {
    let value: unknown;
    try {
      value = fn(...args);
    } catch (error) {
      return { kind: "error", text: String(error) };
    }
    return classify(value);
  };
}

function classify(value: unknown): native.NativeSqlFunctionResult {
  if (value === null || value === undefined) {
    return { kind: "null" };
  }
  switch (typeof value) {
    case "bigint":
      return { kind: "integer", integer: value };
    case "number":
      return { kind: "float", float: value };
    case "boolean":
      return { kind: "integer", integer: value ? 1n : 0n };
    case "string":
      return { kind: "text", text: value };
  }
  if (value instanceof Uint8Array) {
    return { kind: "blob", blob: value };
  }
  const name = typeof value === "object" ? value.constructor?.name ?? "object" : typeof value;
  return { kind: "error", text: `unsupported SQL function result type ${name}` };
}
