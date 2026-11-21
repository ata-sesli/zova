export type VectorMetric = "cosine" | "l2" | "dot";
export type VectorElementType = "f32" | "f16" | "i8";
export type VectorValues = Float32Array | Uint16Array | Int8Array;

export interface VectorCollectionOptions {
  readonly dimensions: number;
  readonly metric: VectorMetric;
  readonly elementType: VectorElementType;
}

export interface VectorCollectionInfo extends VectorCollectionOptions {
  readonly name: string;
  readonly vectorCount: bigint;
}

export interface VectorInput {
  readonly id: string;
  readonly values: VectorValues;
}

export interface Vector {
  readonly id: string;
  readonly values: VectorValues;
}

export interface VectorSearchResult {
  readonly id: string;
  readonly distance: number;
}

export interface VectorSearchOptions {
  readonly candidateIds?: readonly string[];
  readonly maxDistance?: number;
  readonly limit: number;
}

/**
 * `global-min-cosine` scores each stored vector by its least similar query
 * row. `cbm-prefilter-min-cosine` first keeps the `prefilterLimit` nearest
 * vectors to row `prefilterQueryIndex`, then scores those the same way.
 */
export type VectorMultiI8SearchMode = "global-min-cosine" | "cbm-prefilter-min-cosine";
export type VectorMultiI8Aggregation = "min-cosine";

export interface VectorMultiI8SearchOptions {
  /** `queryCount` rows of `dimensions` values each, row after row. */
  readonly queryValues: Int8Array;
  readonly queryCount: number;
  readonly dimensions: number;
  /** Restrict the search to these vector ids. */
  readonly candidateIds?: readonly string[];
  readonly mode?: VectorMultiI8SearchMode;
  readonly aggregation?: VectorMultiI8Aggregation;
  readonly prefilterQueryIndex?: number;
  readonly prefilterLimit?: number;
  readonly limit: number;
}
