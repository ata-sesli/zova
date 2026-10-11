export enum Step {
  Row = "row",
  Done = "done",
}

export type ColumnType = "integer" | "float" | "text" | "blob" | "null";

export interface OpenOptions {
  readonly readOnly?: boolean;
  readonly busyTimeoutMs?: number;
  readonly extensions?: ExtensionOptions;
}

/** Explicit native bundle selection, not a trust grant. Code must match the host. */
export interface ExtensionOptions {
  readonly bundlePaths: readonly string[];
  readonly trustStorePath?: string;
}

/** Copy only the array container for the synchronous native request. */
export function nativeExtensionOptions(options?: ExtensionOptions):
  { bundlePaths: string[]; trustStorePath?: string } | undefined {
  return options
    ? { bundlePaths: [...options.bundlePaths], trustStorePath: options.trustStorePath }
    : undefined;
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

export type FormatCompatibilityName =
  | "current"
  | "migratable"
  | "unsupported_legacy"
  | "unsupported_future";

export interface FormatInfo {
  readonly formatVersion: number;
  readonly compatibility: FormatCompatibilityName;
}

export interface KvEntry {
  readonly key: Uint8Array;
  readonly value: Uint8Array;
}
