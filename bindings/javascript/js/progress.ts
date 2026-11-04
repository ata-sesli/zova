import native = require("../index.js");

import { normalizeNativeError } from "./errors.js";

/** The stage of a backup, compact, or migration; fixes the unit of `done` and `total`. */
export type ProgressPhase = "copy" | "migrate" | "verify" | "publish";

/** The member file a copy or migrate event refers to. */
export type ProgressMember = "main" | "object_store" | "vector_store" | "graph_store";

/**
 * One progress event. `copy` counts SQLite pages, `migrate` format steps,
 * `verify` stored items, and `publish` files. Events for one phase and member
 * keep `total` fixed, never decrease `done`, and end with `done === total`.
 * `member` is `null` for the whole-set `verify` and `publish` phases.
 */
export interface Progress {
  readonly phase: ProgressPhase;
  readonly member: ProgressMember | null;
  readonly done: number;
  readonly total: number;
}

/**
 * Progress reporting and cancellation for an asynchronous backup, compact,
 * or migration.
 *
 * The operation runs on a worker thread and never waits for JavaScript, so
 * `progress` receives events asynchronously; every event is delivered before
 * the returned promise settles. Aborting `signal` cancels the operation at its
 * next progress event, and the promise rejects with a `ZovaError` whose code
 * is `ZOVA_INTERRUPTED`. An exception thrown by `progress` also cancels it and
 * rejects the promise with that exception.
 */
export interface ProgressOptions {
  readonly progress?: (progress: Progress) => void;
  readonly signal?: AbortSignal;
}

type NativeProgressCallback = (progress: native.NativeProgress | null) => void;

export async function withProgress(
  options: ProgressOptions | undefined,
  start: (
    progress: NativeProgressCallback | undefined,
    cancel: native.NativeCancelToken | undefined,
  ) => Promise<void>,
): Promise<void> {
  const callback = options?.progress;
  const signal = options?.signal;
  if (callback === undefined && signal === undefined) {
    return start(undefined, undefined);
  }

  const token = new native.NativeCancelToken();
  const onAbort = () => token.cancel();
  if (signal?.aborted) {
    token.cancel();
  } else {
    signal?.addEventListener("abort", onAbort, { once: true });
  }

  let thrown: { error: unknown } | undefined;
  let drained: Promise<void> = Promise.resolve();
  let nativeCallback: NativeProgressCallback | undefined;
  if (callback !== undefined) {
    let markDrained!: () => void;
    drained = new Promise((resolve) => {
      markDrained = resolve;
    });
    nativeCallback = (event) => {
      if (event === null) {
        markDrained();
        return;
      }
      if (thrown !== undefined) {
        return;
      }
      try {
        callback({
          phase: event.phase as ProgressPhase,
          member: (event.member ?? null) as ProgressMember | null,
          done: event.done,
          total: event.total,
        });
      } catch (error) {
        thrown = { error };
        token.cancel();
      }
    };
  }

  try {
    const pending = start(nativeCallback, token);
    let failure: { error: unknown } | undefined;
    try {
      await pending;
    } catch (error) {
      failure = { error };
    }
    await drained;
    if (thrown !== undefined) {
      throw thrown.error;
    }
    if (failure !== undefined) {
      throw normalizeNativeError(failure.error);
    }
  } finally {
    signal?.removeEventListener("abort", onAbort);
  }
}
