const encoder = new TextEncoder();
const decoder = new TextDecoder();
const invalid = message => Object.assign(new Error(message), { status: "ZOVA_INVALID_ARGUMENT", statusCode: 1 });

function sqlText(sql) {
  if (typeof sql !== "string" || sql.includes("\0")) throw invalid("SQL must be a string without NUL bytes");
  return encoder.encode(sql + "\0");
}
function sqlValue(value) {
  if (value === null) return [0, 0n, 0, new Uint8Array()];
  if (typeof value === "bigint") {
    if (value < -(1n << 63n) || value >= (1n << 63n)) throw invalid("Integer is outside signed 64-bit range");
    return [1, value, 0, new Uint8Array()];
  }
  if (typeof value === "number" && Number.isFinite(value)) return [2, 0n, value, new Uint8Array()];
  if (typeof value === "string") return [3, 0n, 0, encoder.encode(value)];
  if (value instanceof Uint8Array) return [4, 0n, 0, value];
  throw invalid("Unsupported SQL parameter");
}

export function serveWorker(createModule, port = globalThis) {
  let module;
  let state = "new";
  let lastId = 0;
  let queue = Promise.resolve();
  const check = status => {
    if (status === 0) return;
    const pointer = module._zw_error();
    const name = module.UTF8ToString(module._zw_status_name(status));
    throw Object.assign(new Error(pointer ? module.UTF8ToString(pointer) : name), { status: name, statusCode: status });
  };
  const withBytes = (bytes, use) => {
    const pointer = module._malloc(Math.max(bytes.length, 1));
    if (!pointer) throw new Error("WASM allocation failed");
    try {
      module.HEAPU8.set(bytes, pointer);
      return use(pointer, bytes.length);
    } finally { module._free(pointer); }
  };
  const readBytes = () => {
    const pointer = module._zw_bytes();
    const length = module._zw_length();
    // Obtain a fresh view after every native call: memory growth replaces it.
    return module.HEAPU8.slice(pointer, pointer + length);
  };
  const query = args => {
    const sql = sqlText(args.sql);
    if (!Array.isArray(args.parameters ?? [])) throw invalid("Parameters must be an array");
    const parameters = (args.parameters ?? []).map(sqlValue);
    withBytes(sql, pointer => check(module._zw_prepare(pointer)));
    try {
      check(module._zw_count(1));
      if (module._zw_number() !== parameters.length) throw invalid("Parameter count mismatch");
      parameters.forEach(([type, integer, real, bytes], index) => {
        withBytes(bytes, (pointer, length) => check(module._zw_bind(index + 1, type, integer, real, pointer, length)));
      });
      check(module._zw_count(0));
      const count = module._zw_number();
      const columns = [];
      for (let index = 0; index < count; index++) {
        check(module._zw_name(index));
        columns.push(decoder.decode(readBytes()));
      }
      const rows = [];
      while (true) {
        check(module._zw_step());
        if (module._zw_number() === 2) break;
        const row = [];
        for (let index = 0; index < count; index++) {
          check(module._zw_column(index));
          switch (module._zw_number()) {
            case 1: row.push(module._zw_integer()); break;
            case 2: row.push(module._zw_float()); break;
            case 3: row.push(decoder.decode(readBytes())); break;
            case 4: row.push(readBytes()); break;
            case 5: row.push(null); break;
            default: throw new Error("Unknown SQL column type");
          }
        }
        rows.push(row);
      }
      return { columns, rows };
    } finally { check(module._zw_finalize()); }
  };
  const dispatch = async (operation, args) => {
    if (operation === "initialize") {
      if (state !== "new") throw invalid("Worker already initialized");
      state = "initializing";
      module = await createModule();
      check(module._zw_create());
      state = "open";
      return;
    }
    if (operation === "close" && state === "closed") return;
    if (state !== "open") throw invalid("Database is not open");
    switch (operation) {
      case "exec": return withBytes(sqlText(args.sql), pointer => check(module._zw_exec(pointer)));
      case "query": return query(args);
      case "kv_get": case "kv_put": case "kv_delete": {
        const value = operation === "kv_put" ? args.value : new Uint8Array();
        if (![args.namespace, args.key, value].every(x => x instanceof Uint8Array)) throw invalid("KV inputs must be Uint8Array values");
        const op = operation === "kv_get" ? 0 : operation === "kv_put" ? 1 : 2;
        return withBytes(args.namespace, (ns, nsLen) => withBytes(args.key, (key, keyLen) => withBytes(value, (data, len) => {
          check(module._zw_kv(op, ns, nsLen, key, keyLen, data, len));
          if (op === 0) return module._zw_number() ? readBytes() : null;
          if (op === 2) return Boolean(module._zw_number());
        })));
      }
      case "close": check(module._zw_close()); state = "closed"; return;
      default: throw invalid("Unknown worker operation");
    }
  };
  port.addEventListener("message", event => {
    const request = event.data;
    queue = queue.then(async () => {
      let fatal = false;
      try {
        if (!Number.isSafeInteger(request?.id) || request.id <= lastId) throw invalid("Request IDs must increase");
        lastId = request.id;
        const value = await dispatch(request.operation, request.args ?? {});
        port.postMessage({ id: request.id, ok: true, value });
      } catch (error) {
        fatal = state === "initializing" || error instanceof WebAssembly.RuntimeError;
        if (fatal) state = "failed";
        port.postMessage({ id: request?.id, ok: false, fatal, error: {
          message: String(error.message ?? error), status: error.status, statusCode: error.statusCode,
        } });
      } finally {
        if (module && state !== "failed") module._zw_release();
      }
    });
  });
}
