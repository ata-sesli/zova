// Page-side helpers shared by browser tests. Served as /helpers.mjs.

// Fresh random identities that every migration, native or browser, creates.
const migrationIdentities = { _zova_vector_sources: ["incarnation", "token", "floor_token"] };

// Every table's rows as SQLite literals, sorted, plus the schema. SQLite
// formats the values, so equal dumps mean equal stored contents. Random
// migration identities are reduced to their byte length.
export async function dump(db) {
  const parts = [];
  const schema = await db.query("SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name");
  parts.push(schema.rows.map(row => row.join("|")).join("\n"));
  for (const [type, table] of schema.rows) {
    if (type !== "table") continue;
    const columns = (await db.query("SELECT name FROM pragma_table_info(?) ORDER BY cid", [table])).rows.map(row => row[0]);
    const masked = migrationIdentities[table] ?? [];
    const quoted = columns.map(column => masked.includes(column) ? `length("${column}")` : `quote("${column}")`).join(" || ',' || ");
    const rows = await db.query(`SELECT ${quoted} FROM "${table}" ORDER BY 1`);
    parts.push(table + "\n" + rows.rows.map(row => row[0]).join("\n"));
  }
  return parts.join("\n\n");
}

// The same contents read through the public object, vector, graph and KV APIs.
export async function summary(db) {
  const hex = bytes => Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  const out = { objects: [], vectors: [], graphs: [], kv: [] };
  for (const [id] of (await db.query("SELECT object_id FROM _zova_objects ORDER BY object_id")).rows) {
    const data = await db.getObject(id);
    out.objects.push([hex(id), data.length, hex(new Uint8Array(await crypto.subtle.digest("SHA-256", data)))]);
  }
  for (const info of await db.listVectorCollections()) {
    const ids = (await db.query("SELECT vector_id FROM _zova_vectors v JOIN _zova_vector_collections c USING (collection_key) WHERE c.name = ? ORDER BY vector_id", [info.name])).rows;
    for (const [id] of ids) {
      const vector = await db.getVector(info.name, id);
      const nearest = await db.searchVectorsById(info.name, id, 3);
      out.vectors.push([info.name, info.metric, info.elementType, id, Array.from(vector.values).join(","), nearest.map(item => item.id).join(",")]);
    }
  }
  for (const graph of await db.listGraphs()) {
    const nodes = (await db.query("SELECT node_id FROM _zova_graph_nodes n JOIN _zova_graphs g USING (graph_key) WHERE g.name = ? ORDER BY node_id", [graph.name])).rows;
    for (const [nodeId] of nodes) {
      const node = await db.getGraphNode(graph.name, nodeId);
      const walk = await db.graphWalk({ graphName: graph.name, startNodeId: nodeId, maxDepth: 3, limit: 50 });
      out.graphs.push([graph.name, String(graph.nodeCount), String(graph.edgeCount), JSON.stringify(node), walk.map(item => item.nodeId + "@" + item.depth).join(",")]);
    }
  }
  for (const [namespace, key] of (await db.query("SELECT namespace, key FROM _zova_kv ORDER BY namespace, key")).rows) {
    const value = await db.kv.get(namespace, key);
    out.kv.push([hex(namespace), hex(key), value === null ? null : hex(value)]);
  }
  return JSON.stringify(out);
}

// Writes raw database bytes into a persistent name's pool, bypassing open
// validation, as a stored older-format database would be.
export function seed(name, bytes) {
  return new Promise((resolve, reject) => {
    const worker = new Worker("/seed.mjs", { type: "module" });
    worker.onmessage = ({ data }) => { worker.terminate(); data.error ? reject(new Error(data.error)) : resolve(); };
    worker.onerror = event => { worker.terminate(); reject(new Error(event.message)); };
    worker.postMessage({ name, bytes }, [bytes.buffer]);
  });
}

export async function fetchBytes(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

export async function status(promise) {
  try { await promise; return "ok"; } catch (error) { return error?.status ?? String(error); }
}

// Retries ZOVA_BUSY while a terminated worker's lock is released.
export async function retryBusy(operation) {
  const deadline = performance.now() + 5000;
  for (;;) {
    try { return await operation(); }
    catch (error) {
      if (error?.status !== "ZOVA_BUSY" || performance.now() >= deadline) throw error;
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
}

export async function sha256(bytes) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), byte => byte.toString(16).padStart(2, "0")).join("");
}

// SHA-256 of a persistent name's stored main file, read without opening it.
export function snapshot(name) {
  return new Promise((resolve, reject) => {
    const worker = new Worker("/snapshot.mjs", { type: "module" });
    worker.onmessage = ({ data }) => {
      worker.terminate();
      data.error ? reject(new Error(data.error)) : resolve(data.hash.map(byte => byte.toString(16).padStart(2, "0")).join(""));
    };
    worker.onerror = event => { worker.terminate(); reject(new Error(event.message)); };
    worker.postMessage(name);
  });
}
