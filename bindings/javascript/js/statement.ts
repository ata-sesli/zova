import native = require("../index.js");

import { callNative } from "./errors.js";
import { Step, type ColumnType } from "./types.js";

export class Statement {
  readonly #native: native.NativeStatement;

  constructor(statement: native.NativeStatement) {
    this.#native = statement;
  }

  get closed(): boolean {
    return this.#native.closed;
  }

  close(): void {
    callNative(() => this.#native.close());
  }

  parameterCount(): number {
    return callNative(() => this.#native.parameterCount());
  }

  parameterIndex(name: string): number | null {
    return callNative(() => this.#native.parameterIndex(name));
  }

  bindNull(index: number): void {
    callNative(() => this.#native.bindNull(index));
  }

  bindInteger(index: number, value: bigint): void {
    callNative(() => this.#native.bindInteger(index, value));
  }

  bindFloat(index: number, value: number): void {
    callNative(() => this.#native.bindFloat(index, value));
  }

  bindText(index: number, value: string): void {
    callNative(() => this.#native.bindText(index, value));
  }

  bindBlob(index: number, value: Uint8Array): void {
    callNative(() => this.#native.bindBlob(index, value));
  }

  step(): Step {
    return callNative(() => this.#native.step()) as Step;
  }

  reset(): void {
    callNative(() => this.#native.reset());
  }

  clearBindings(): void {
    callNative(() => this.#native.clearBindings());
  }

  columnCount(): number {
    return callNative(() => this.#native.columnCount());
  }

  columnName(index: number): string {
    return callNative(() => this.#native.columnName(index));
  }

  columnType(index: number): ColumnType {
    return callNative(() => this.#native.columnType(index)) as ColumnType;
  }

  columnInteger(index: number): bigint {
    return callNative(() => this.#native.columnInteger(index));
  }

  columnFloat(index: number): number {
    return callNative(() => this.#native.columnFloat(index));
  }

  columnText(index: number): string | null {
    return callNative(() => this.#native.columnText(index));
  }

  columnBlob(index: number): Uint8Array | null {
    return callNative(() => this.#native.columnBlob(index));
  }
}
