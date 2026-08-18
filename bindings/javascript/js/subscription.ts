import native = require("../index.js");

import { callNative, normalizeNativeError } from "./errors.js";

export interface Notification {
  readonly channel: string;
  readonly payload: string;
  readonly sequence: bigint;
  readonly droppedBefore: bigint;
}

export class Subscription {
  readonly #native: native.NativeSubscription;

  private constructor(subscription: native.NativeSubscription) {
    this.#native = subscription;
  }

  static create(subscription: native.NativeSubscription): Subscription {
    return new Subscription(subscription);
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  close(): void {
    callNative(() => this.#native.close());
  }

  tryReceive(): Notification | null {
    return callNative(() => this.#native.tryReceive());
  }

  async tryReceiveAsync(): Promise<Notification | null> {
    try {
      return await this.#native.asyncTryReceive();
    } catch (error) {
      throw normalizeNativeError(error);
    }
  }
}
