import native = require("../index.js");

import { callNative, invalidArgument } from "./errors.js";

/**
 * A C-v1 plugin descriptor (`zova_plugin_descriptor_v1`) linked into this
 * process. Linked plugins need no `.zovaext` bundle and no trust record: the
 * host vouches for code it links. Pass them through `ExtensionOptions.plugins`.
 */
export class LinkedPlugin {
  /** Address of the descriptor. */
  readonly address: bigint;

  private constructor(address: bigint) {
    this.address = address;
  }

  /**
   * Wrap the descriptor at `address`, such as a pointer from an FFI library.
   *
   * Zova cannot check this address. The descriptor and everything it points
   * to must stay valid and unchanged for the rest of the process and satisfy
   * the `zova_plugin.h` contract: NUL-terminated metadata strings, and hooks
   * that are safe to call on any thread that uses a database opened with
   * this plugin. A wrong address crashes the process.
   */
  static fromAddress(address: bigint | number): LinkedPlugin {
    const value = typeof address === "number" ? numberAddress(address) : address;
    if (value <= 0n || value > 0xffff_ffff_ffff_ffffn) {
      throw invalidArgument("linked plugin address must be a non-zero pointer");
    }
    return new LinkedPlugin(value);
  }
}

function numberAddress(address: number): bigint {
  if (!Number.isSafeInteger(address)) {
    throw invalidArgument("linked plugin address must be a non-zero pointer");
  }
  return BigInt(address);
}

/**
 * Load a `.zovaext` bundle's entrypoint and validate it without trusting it.
 * Omitting `trustStorePath` selects Zova's default trust store.
 */
export function verifyExtensionBundle(bundlePath: string, trustStorePath?: string): void {
  callNative(() => native.verifyExtensionBundle(bundlePath, trustStorePath));
}

/** Record a bundle's manifest and library hash in the selected trust store. */
export function trustExtensionBundle(bundlePath: string, trustStorePath?: string): void {
  callNative(() => native.trustExtensionBundle(bundlePath, trustStorePath));
}

/**
 * Remove trust records matching a bundle path or an extension name. Returns
 * whether any record was removed.
 */
export function untrustExtensionBundle(identifier: string, trustStorePath?: string): boolean {
  return callNative(() => native.untrustExtensionBundle(identifier, trustStorePath));
}
