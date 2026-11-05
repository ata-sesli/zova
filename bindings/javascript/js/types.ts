import type { ProgressMember } from "./progress.js";

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

/** SQLite `auto_vacuum` mode of one member file. */
export type AutoVacuumMode = "none" | "full" | "incremental";

/**
 * Options for `reclaimSpace`. `maxPages` bounds the pages released by the
 * call across every member (default 0: every free page); `stepPages` is the
 * number of pages released per write transaction (default 1024).
 */
export interface ReclaimOptions {
  readonly maxPages?: number;
  readonly stepPages?: number;
}

/**
 * What `reclaimSpace` did for one member file. When `autoVacuum` is `"none"`
 * the member releases nothing and only `compactTo` drops its free pages.
 */
export interface ReclaimedMember {
  readonly member: ProgressMember;
  readonly autoVacuum: AutoVacuumMode;
  readonly pageSize: number;
  readonly pagesReleased: number;
  readonly freePagesLeft: number;
}

export function reclaimedMember(raw: {
  member: string;
  autoVacuum: string;
  pageSize: number;
  pagesReleased: number;
  freePagesLeft: number;
}): ReclaimedMember {
  return {
    member: raw.member as ProgressMember,
    autoVacuum: raw.autoVacuum as AutoVacuumMode,
    pageSize: raw.pageSize,
    pagesReleased: raw.pagesReleased,
    freePagesLeft: raw.freePagesLeft,
  };
}

export interface KvEntry {
  readonly key: Uint8Array;
  readonly value: Uint8Array;
}
