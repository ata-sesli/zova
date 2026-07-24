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
