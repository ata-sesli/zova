export enum Step {
  Row = "row",
  Done = "done",
}

export type ColumnType = "integer" | "float" | "text" | "blob" | "null";

export interface OpenOptions {
  readonly readOnly?: boolean;
  readonly busyTimeoutMs?: number;
}

export interface ExtensionInfo {
  name: string;
  version: string;
  storagePrefix: string;
  zovaAbiMin: string;
  capabilities: string;
  required: boolean;
  installedAtUnix: bigint;
  manifestJson: string;
}

export interface KvEntry {
  readonly key: Uint8Array;
  readonly value: Uint8Array;
}
