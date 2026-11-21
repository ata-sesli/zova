import native = require("../index.js");

import { callNative } from "./errors.js";
import type { GraphFreshEdgeInput, GraphFreshNodeInput } from "./graph.js";
import type { VectorInput } from "./vector.js";

/**
 * One fresh-build cell: `null`, an integer `bigint`, a float `number`, text,
 * or a blob.
 */
export type FreshValue = null | bigint | number | string | Uint8Array;

/** Where a fresh build spent its time; timings are milliseconds. */
export interface FreshBuildProfile {
  readonly validationMs: number;
  readonly tableLoadMs: number;
  readonly ftsLoadMs: number;
  readonly graphLoadMs: number;
  readonly graphValidationMs: number;
  readonly graphKeyGenerationMs: number;
  readonly graphNodeLoadMs: number;
  readonly graphEdgeLoadMs: number;
  readonly vectorLoadMs: number;
  readonly indexBuildMs: number;
  readonly commitMs: number;
  readonly tableRows: number;
  readonly ftsRows: number;
  readonly vectorRows: number;
  readonly payloadBytes: number;
}

export interface FreshBuildResult {
  /** Keys of the session's graph nodes, in input order. */
  readonly nodeKeys: BigInt64Array;
  /** Keys of the session's graph edges, in input order. */
  readonly edgeKeys: BigInt64Array;
  readonly profile: FreshBuildProfile;
}

/**
 * A fresh-build session: bulk-load empty tables, FTS tables, one graph, and
 * vector collections, then commit them together.
 *
 * While the session is open every other call on its database fails, and the
 * database cannot close. `finish` commits. `abort`, `close`, and any failure,
 * including invalid input, roll the whole session back.
 */
export class FreshBuild {
  readonly #native: native.NativeFreshBuild;

  constructor(build: native.NativeFreshBuild) {
    this.#native = build;
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  /** Append rows to an empty ordinary table; each row has one value per column. */
  tableRows(
    tableName: string,
    columns: readonly string[],
    rows: readonly (readonly FreshValue[])[],
  ): void {
    callNative(() =>
      this.#native.tableRows(tableName, [...columns], rows as FreshValue[][]),
    );
  }

  /** Append rows to an empty FTS5 table; each row has one value per column. */
  ftsRows(
    tableName: string,
    columns: readonly string[],
    rows: readonly (readonly FreshValue[])[],
  ): void {
    callNative(() =>
      this.#native.ftsRows(tableName, [...columns], rows as FreshValue[][]),
    );
  }

  /** Load one new graph. Edges name nodes by position and may carry payloads. */
  graph(
    graphName: string,
    nodes: readonly GraphFreshNodeInput[],
    edges: readonly GraphFreshEdgeInput[],
  ): void {
    callNative(() => this.#native.graph(graphName, [...nodes], [...edges]));
  }

  /** Load vectors into an empty collection. */
  vectors(collectionName: string, vectors: readonly VectorInput[]): void {
    callNative(() => this.#native.vectors(collectionName, [...vectors]));
  }

  /** Commit the session and close it. */
  finish(): FreshBuildResult {
    return callNative(() => this.#native.finish());
  }

  /** Roll the session back and close it. */
  abort(): void {
    callNative(() => this.#native.abort());
  }

  /** Roll back an unfinished session. Closing a closed session does nothing. */
  close(): void {
    callNative(() => this.#native.close());
  }
}
