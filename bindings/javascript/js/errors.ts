const encodedErrorPattern =
  /__ZOVA_ERROR__:(-?\d+):([^:]+):([\s\S]*)$/;

export class ZovaError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status: number, message: string) {
    super(message);
    this.name = "ZovaError";
    this.code = code;
    this.status = status;
  }
}

export function normalizeNativeError(error: unknown): unknown {
  if (error instanceof ZovaError) {
    return error;
  }
  if (!(error instanceof Error)) {
    return error;
  }
  const match = encodedErrorPattern.exec(error.message);
  if (match === null) {
    return error;
  }
  return new ZovaError(match[2], Number(match[1]), match[3]);
}

export function callNative<T>(operation: () => T): T {
  try {
    return operation();
  } catch (error) {
    throw normalizeNativeError(error);
  }
}

export function invalidArgument(message: string): ZovaError {
  return new ZovaError("ZOVA_INVALID_ARGUMENT", 1, message);
}
