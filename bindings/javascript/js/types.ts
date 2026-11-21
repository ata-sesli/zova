import type { LinkedPlugin } from "./extension.js";
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

/**
 * Explicit native bundle selection, not a trust grant. Code must match the
 * host. `plugins` adds descriptors linked into this process.
 */
export interface ExtensionOptions {
  readonly bundlePaths?: readonly string[];
  readonly trustStorePath?: string;
  readonly plugins?: readonly LinkedPlugin[];
}

/** Settings applied when a new database file is created. */
export interface CreateOptions {
  /** SQLite page size in bytes; omitted or 0 keeps SQLite's default. */
  readonly pageSize?: number;
}

/** Copy only the array containers for the synchronous native request. */
export function nativeExtensionOptions(options?: ExtensionOptions):
  { bundlePaths: string[]; trustStorePath?: string; plugins?: bigint[] } | undefined {
  return options
    ? {
        bundlePaths: [...(options.bundlePaths ?? [])],
        trustStorePath: options.trustStorePath,
        plugins: options.plugins?.map((plugin) => plugin.address),
      }
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

/**
 * Selects one page of a key-value namespace. Keys compare as raw bytes: a
 * shorter key sorts before every longer key it prefixes. Every given bound
 * applies. Continue a scan by passing the last returned key as `after`.
 */
export interface KvScanOptions {
  /** Only keys that begin with these bytes. */
  readonly prefix?: Uint8Array;
  /** Inclusive lower bound. */
  readonly start?: Uint8Array;
  /** Exclusive upper bound. */
  readonly end?: Uint8Array;
  /** Continue strictly after this key. */
  readonly after?: Uint8Array;
  /** Most entries returned; must be a positive integer. */
  readonly limit: number;
  /** Return keys only; every value is then empty. */
  readonly keysOnly?: boolean;
}

/** One scan page in ascending key byte order. */
export interface KvScanPage {
  readonly entries: KvEntry[];
  /** True when at least one further entry matches the same options. */
  readonly hasMore: boolean;
}
