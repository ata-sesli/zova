const encoder = new TextEncoder();
const decoder = new TextDecoder();
const invalid = message => Object.assign(new Error(message), { status: "ZOVA_INVALID_ARGUMENT", statusCode: 1 });

function acquireOwnership(name) {
  if (!globalThis.navigator?.locks?.request) {
    throw Object.assign(new Error("Web Locks are required for persistent databases"), { status: "ZOVA_CANT_OPEN", statusCode: 13 });
  }
  return new Promise((resolve, reject) => {
    let unlock;
    const held = new Promise(release => { unlock = release; });
    // Hold the callback open for the entire storage lifetime. Never queue or
    // steal a lock. Worker termination also releases this browser-owned lock.
    const released = navigator.locks.request("zova:opfs:" + name,
      { mode: "exclusive", ifAvailable: true }, lock => {
        if (!lock) {
          reject(Object.assign(new Error("Database is in use: " + name), { status: "ZOVA_BUSY", statusCode: 10 }));
          return;
        }
        resolve(async () => { unlock(); await released; });
        return held;
      });
    released.catch(reject);
  });
}

const metrics = ["cosine", "l2", "dot"];
const elementTypes = ["f32", "f16", "i8"];
const targetTypes = ["none", "record", "object", "object-chunk", "vector", "entity", "fact", "concept", "external"];
const directions = ["outgoing", "incoming"];
const absent = 0xffffffff;
function code(names, value, label) {
  const index = names.indexOf(value);
  if (index < 0) throw invalid("Unknown " + label);
  return index;
}
function count(value, label) {
  if (!Number.isInteger(value) || value < 0 || value >= absent) throw invalid(label + " must be a non-negative integer");
  return value;
}
function vectorValues(values) {
  const type = values instanceof Float32Array ? 0 : values instanceof Uint16Array ? 1 : values instanceof Int8Array ? 2 : -1;
  if (type < 0) throw invalid("Vector values must be a Float32Array, Uint16Array or Int8Array");
  return [type, values];
}

// Request and reply encoding shared with native/bridge.c: little-endian fields
// padded to four bytes, NUL-terminated strings, `absent` for a missing string.
function request() {
  let buffer = new Uint8Array(256);
  let view = new DataView(buffer.buffer);
  let length = 0;
  const reserve = size => {
    const start = length;
    length += Math.ceil(size / 4) * 4;
    if (length > buffer.length) {
      const grown = new Uint8Array(Math.max(length, buffer.length * 2));
      grown.set(buffer);
      buffer = grown;
      view = new DataView(buffer.buffer);
    }
    return start;
  };
  const self = {
    u32(value) { const at = reserve(4); view.setUint32(at, value, true); return self; },
    u64(value) {
      if (typeof value !== "bigint" || value < 0n || value >= (1n << 64n)) throw invalid("Expected an unsigned 64-bit bigint");
      const at = reserve(8); view.setBigUint64(at, value, true); return self;
    },
    // Reserve before touching `buffer`: growth replaces it.
    raw(bytes) {
      if (!(bytes instanceof Uint8Array)) throw invalid("Expected a Uint8Array");
      const at = reserve(bytes.length); buffer.set(bytes, at); return self;
    },
    bytes(bytes) { return self.u32(count(bytes.length, "Byte length")).raw(bytes); },
    str(text) {
      if (text === undefined || text === null) return self.u32(absent);
      if (typeof text !== "string" || text.includes("\0")) throw invalid("Names and identifiers must be strings without NUL bytes");
      const bytes = encoder.encode(text);
      self.u32(count(bytes.length, "Text length"));
      const at = reserve(bytes.length + 1); buffer.set(bytes, at);
      return self;
    },
    values(values) {
      const [type, data] = vectorValues(values);
      return self.u32(type).u32(count(data.length, "Vector length")).raw(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
    },
    each(items, write) {
      if (!Array.isArray(items)) throw invalid("Expected an array");
      self.u32(count(items.length, "Item count"));
      for (const item of items) write(self, item);
      return self;
    },
    finish: () => buffer.subarray(0, length),
  };
  return self;
}
function reply(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 0;
  const take = size => { const start = at; at += Math.ceil(size / 4) * 4; return start; };
  const self = {
    all: bytes,
    u32: () => view.getUint32(take(4), true),
    u64: () => view.getBigUint64(take(8), true),
    f64: () => view.getFloat64(take(8), true),
    raw: size => { const start = take(size); return bytes.slice(start, start + size); },
    str: () => {
      const size = self.u32();
      if (size === absent) return undefined;
      const start = take(size);
      return decoder.decode(bytes.subarray(start, start + size));
    },
    list: read => Array.from({ length: self.u32() }, () => read(self)),
    values: () => {
      const type = self.u32();
      const length = self.u32();
      const raw = self.raw(length * [4, 2, 1][type]).buffer;
      return type === 0 ? new Float32Array(raw) : type === 1 ? new Uint16Array(raw) : new Int8Array(raw);
    },
  };
  return self;
}
const readCollection = r => ({ name: r.str(), dimensions: r.u32(), metric: metrics[r.u32()], elementType: elementTypes[r.u32()], vectorCount: r.u64() });
const readGraph = r => ({ name: r.str(), nodeCount: r.u64(), edgeCount: r.u64() });
const readSearch = r => ({ id: r.str(), distance: r.f64() });
const writeNode = (w, node) => w.str(node.graphName).str(node.nodeId).str(node.kind)
  .u32(code(targetTypes, node.targetType, "graph target type")).str(node.targetNamespace).str(node.targetRef);
const writeEdge = (w, edge) => w.str(edge.graphName).str(edge.fromNodeId).str(edge.edgeType).str(edge.toNodeId);
const writeText = (w, text) => { if (typeof text !== "string") throw invalid("Identifiers must be strings"); w.str(text); };
function objectId(id) {
  if (!(id instanceof Uint8Array) || id.length !== 32) throw invalid("Object IDs are 32-byte Uint8Array values");
  return id;
}

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
  let pool;
  let releaseOwnership;
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
  // The helpers below act on the statement last prepared or selected.
  const bindAll = values => {
    if (!Array.isArray(values ?? [])) throw invalid("Parameters must be an array");
    const parameters = (values ?? []).map(sqlValue);
    check(module._zw_count(1));
    if (module._zw_number() !== parameters.length) throw invalid("Parameter count mismatch");
    parameters.forEach(([type, integer, real, bytes], index) => {
      withBytes(bytes, (pointer, length) => check(module._zw_bind(index + 1, type, integer, real, pointer, length)));
    });
  };
  const columnNames = () => {
    check(module._zw_count(0));
    const count = module._zw_number();
    const columns = [];
    for (let index = 0; index < count; index++) {
      check(module._zw_name(index));
      columns.push(decoder.decode(readBytes()));
    }
    return columns;
  };
  const readRows = (count, limit) => {
    const rows = [];
    while (rows.length < limit) {
      check(module._zw_step());
      if (module._zw_number() === 2) return { rows, done: true };
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
    return { rows, done: false };
  };
  const prepare = sql => {
    withBytes(sqlText(sql), pointer => check(module._zw_prepare(pointer)));
    return module._zw_number();
  };
  const query = args => {
    prepare(args.sql);
    try {
      bindAll(args.parameters);
      const columns = columnNames();
      return { columns, rows: readRows(columns.length, Infinity).rows };
    } finally { check(module._zw_finalize()); }
  };
  const call = (op, input) => withBytes(input ? input.finish() : new Uint8Array(), (pointer, length) => {
    check(module._zw_call(op, pointer, length));
    return reply(readBytes());
  });
  const flag = (op, input) => { call(op, input); return Boolean(module._zw_number()); };
  const unsigned = (op, input) => { call(op, input); return BigInt.asUintN(64, module._zw_integer()); };
  const edgeScope = a => request().str(a.graphName).str(a.nodeId).u32(code(directions, a.direction, "graph direction")).str(a.edgeType);
  // Operation numbers are shared with native/bridge.c.
  const calls = {
    object_put: a => call(1, request().bytes(a.data)).raw(32),
    object_get: a => call(2, request().raw(objectId(a.id))).all,
    object_read_range: a => call(3, request().raw(objectId(a.id)).u64(a.offset).u32(count(a.size, "Range size"))).all,
    object_exists: a => flag(4, request().raw(objectId(a.id))),
    object_size: a => unsigned(5, request().raw(objectId(a.id))),
    object_delete: a => void call(6, request().raw(objectId(a.id))),
    vector_collection_create: a => void call(10, request().str(a.name).u32(count(a.options?.dimensions, "Dimensions"))
      .u32(code(metrics, a.options.metric, "vector metric")).u32(code(elementTypes, a.options.elementType, "vector element type"))),
    vector_collection_exists: a => flag(11, request().str(a.name)),
    vector_collection_info: a => readCollection(call(12, request().str(a.name))),
    vector_collections_list: () => call(13, request().str(null)).list(readCollection),
    vector_collection_delete: a => void call(14, request().str(a.name)),
    vector_put_many: a => void call(15, request().str(a.collection).each(a.vectors, (w, vector) => w.str(vector.id).values(vector.values))),
    vector_get: a => { const r = call(16, request().str(a.collection).str(a.id)); return { id: r.str(), values: r.values() }; },
    vector_exists: a => flag(17, request().str(a.collection).str(a.id)),
    vector_delete: a => void call(18, request().str(a.collection).str(a.id)),
    vector_delete_many: a => void call(19, request().str(a.collection).each(a.ids, writeText)),
    vector_search: a => call(20, request().str(a.collection).values(a.query).u32(count(a.limit, "Limit"))).list(readSearch),
    vector_search_by_id: a => call(21, request().str(a.collection).str(a.id).u32(count(a.limit, "Limit"))).list(readSearch),
    graph_create: a => void call(30, request().str(a.name)),
    graph_exists: a => flag(31, request().str(a.name)),
    graph_info: a => readGraph(call(32, request().str(a.name))),
    graphs_list: () => call(33).list(readGraph),
    graph_delete: a => void call(34, request().str(a.name)),
    graph_node_put_many: a => void call(35, request().each(a.nodes, writeNode)),
    graph_node_get: a => {
      const r = call(36, request().str(a.graphName).str(a.nodeId));
      const node = { graphName: r.str(), nodeId: r.str(), kind: r.str(), targetType: targetTypes[r.u32()] };
      const targetNamespace = r.str();
      const targetRef = r.str();
      if (targetNamespace !== undefined) node.targetNamespace = targetNamespace;
      if (targetRef !== undefined) node.targetRef = targetRef;
      return node;
    },
    graph_node_exists: a => flag(37, request().str(a.graphName).str(a.nodeId)),
    graph_node_delete: a => void call(38, request().str(a.graphName).str(a.nodeId)),
    graph_node_delete_many: a => void call(39, request().str(a.graphName).each(a.nodeIds, writeText)),
    graph_edge_put_many: a => void call(40, request().each(a.edges, writeEdge)),
    graph_edge_delete_many: a => void call(41, request().each(a.edges, writeEdge)),
    graph_edge_get: a => { call(42, writeEdge(request(), a)); return { graphName: a.graphName, fromNodeId: a.fromNodeId, edgeType: a.edgeType, toNodeId: a.toNodeId }; },
    graph_edge_exists: a => flag(43, writeEdge(request(), a)),
    graph_edge_delete: a => void call(44, writeEdge(request(), a)),
    graph_neighbors: a => call(45, edgeScope(a).u32(count(a.limit, "Limit")))
      .list(r => ({ nodeId: r.str(), kind: r.str(), edgeType: r.str() })),
    graph_degree: a => unsigned(46, edgeScope(a)),
    graph_walk: a => call(47, edgeScope({ ...a, nodeId: a.startNodeId, direction: a.direction ?? "outgoing" })
      .u32(count(a.maxDepth, "Maximum depth")).u32(count(a.limit, "Limit"))).list(r => {
        const item = { nodeId: r.str(), kind: r.str(), depth: r.u32() };
        const predecessorNodeId = r.str();
        const edgeType = r.str();
        if (predecessorNodeId !== undefined) item.predecessorNodeId = predecessorNodeId;
        if (edgeType !== undefined) item.edgeType = edgeType;
        return item;
      }),
  };
  const dispatch = async (operation, args) => {
    if (operation === "initialize") {
      if (state !== "new") throw invalid("Worker already initialized");
      state = "initializing";
      if (args.data !== undefined && (args.name === undefined || !(args.data instanceof Uint8Array))) throw invalid("Import requires a name and Uint8Array bytes");
      if (args.name !== undefined && (typeof args.name !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(args.name))) throw invalid("Invalid persistent database name");
      let created = false;
      try {
        if (args.name !== undefined) releaseOwnership = await acquireOwnership(args.name);
        module = await createModule();
        if (args.name === undefined) {
          check(module._zw_create());
        } else {
          if (!globalThis.navigator?.storage?.getDirectory || typeof FileSystemFileHandle === "undefined" || !FileSystemFileHandle.prototype.createSyncAccessHandle) {
            throw Object.assign(new Error("OPFS synchronous storage is unavailable"), {status:"ZOVA_CANT_OPEN",statusCode:13});
          }
          const sqlite = await module.zovaOpfsBootstrap();
          pool = await sqlite.installOpfsSAHPoolVfs({directory:".zova-" + args.name,initialCapacity:6});
          const vfs = sqlite.capi.sqlite3_vfs_find("opfs-sahpool");
          if (!vfs || sqlite.capi.sqlite3_vfs_register(vfs,1)) throw new Error("Cannot select OPFS VFS");
          created = !pool.getFileNames().includes("/db.zova");
          if (args.data !== undefined) {
            // Import never replaces stored data; the validated open below
            // decides whether the bytes are an acceptable Zova database.
            if (!created) throw Object.assign(new Error("Database already exists: " + args.name), { status: "ZOVA_DESTINATION_EXISTS", statusCode: 33 });
            try { pool.importDb("/db.zova", args.data); }
            catch (error) { throw Object.assign(new Error(String(error.message ?? error)), { status: "ZOVA_NOT_ZOVA_DATABASE", statusCode: 31 }); }
          }
          check(module._zw_open_file(created && args.data === undefined ? 0 : 1));
          withBytes(sqlText("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;"), pointer => check(module._zw_exec(pointer)));
        }
      } catch (error) {
        if (module) module._zw_close();
        if (pool) {
          if (created) {
            pool.unlink("/db.zova-journal");
            pool.unlink("/db.zova");
          }
          pool.pauseVfs();
        }
        await releaseOwnership?.();
        throw error;
      }
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
      case "begin": return check(module._zw_transaction(0));
      case "commit": return check(module._zw_transaction(1));
      case "rollback": return check(module._zw_transaction(2));
      case "export":
        if (!pool) throw invalid("Only persistent databases can be exported");
        // Fails while a transaction is open, and holds the write lock so the
        // copied file is one committed state.
        check(module._zw_transaction(0));
        try { return pool.exportFile("/db.zova"); }
        finally { check(module._zw_transaction(2)); }
      case "prepare": {
        const handle = prepare(args.sql);
        try {
          check(module._zw_count(1));
          return { handle, parameterCount: module._zw_number(), columns: columnNames() };
        } catch (error) { module._zw_finalize(); throw error; }
      }
      case "statement_query":
        check(module._zw_select(args.handle));
        try {
          check(module._zw_reset());
          bindAll(args.parameters);
          const columns = columnNames();
          return { columns, rows: readRows(columns.length, Infinity).rows };
        } finally { module._zw_reset(); }
      case "statement_bind":
        check(module._zw_select(args.handle));
        check(module._zw_reset());
        try { return bindAll(args.parameters); }
        catch (error) { module._zw_reset(); throw error; }
      case "statement_fetch": {
        check(module._zw_select(args.handle));
        check(module._zw_count(0));
        const columns = module._zw_number();
        try {
          const page = readRows(columns, Math.max(1, count(args.maxRows, "Batch size")));
          if (page.done) module._zw_reset();
          return page;
        } catch (error) { module._zw_reset(); throw error; }
      }
      case "statement_reset":
        check(module._zw_select(args.handle));
        return check(module._zw_reset());
      case "statement_finalize":
        check(module._zw_select(args.handle));
        return check(module._zw_finalize());
      case "close":
        check(module._zw_close());
        pool?.pauseVfs();
        await releaseOwnership?.();
        state = "closed";
        return;
      default:
        if (Object.hasOwn(calls, operation)) return calls[operation](args);
        throw invalid("Unknown worker operation");
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
