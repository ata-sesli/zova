// Records native zova-js results for the keyed graph, edge payload, scan,
// directional walk, fresh-build and multi-vector calls, which the browser
// tests replay: node tools/generate-graph-fixture.mjs <zova-js-directory>
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { decode, encode } from "../tests/fixture-codec.mjs";

const zovaDirectory = process.argv[2];
if (!zovaDirectory) throw new Error("usage: node tools/generate-graph-fixture.mjs <zova-js-directory>");
const zova = createRequire(import.meta.url)(zovaDirectory);
let state = 2222;
const next = () => { state ^= state << 13; state >>>= 0; state ^= state >>> 17; state ^= state << 5; state >>>= 0; return state; };
const bytes = text => new TextEncoder().encode(text);

const setup = [
  "create table files(id integer primary key, path text not null, size real, body blob)",
  "create virtual table bodies using fts5(body)",
];
const db = zova.Database.createMemory();
for (const sql of setup) db.exec(sql);
const targets = { db };
const steps = [];
// Runs one call on native zova-js and records its arguments and result in
// the fixture's JSON form. `store` keeps the result as a later target.
// The "$memory" call opens another memory database: fresh graph builds need
// a database whose graph store is empty.
const step = (call, args, { target = "db", store } = {}) => {
  const encoded = encode(args);
  let expected;
  try {
    const result = call === "$memory" ? zova.Database.createMemory() : targets[target][call](...decode(encoded));
    if (store) targets[store] = result;
    expected = store ? { stored: true } : { result: encode(result ?? null) };
  } catch (error) {
    if (typeof error?.code !== "string") throw error;
    expected = { error: error.code };
  }
  steps.push({ target, call, args: encoded, ...(store ? { store } : {}), expected });
  return expected.result === undefined ? undefined : decode(expected.result);
};
// Rows of a query, read through native prepared statements.
const rows = (target, sql) => {
  const statement = targets[target].prepare(sql);
  const out = [];
  try {
    while (statement.step() === "row") {
      const row = [];
      for (let index = 0; index < statement.columnCount(); index++) {
        const type = statement.columnType(index);
        row.push(type === "integer" ? statement.columnInteger(index) : type === "float" ? statement.columnFloat(index)
          : type === "text" ? statement.columnText(index) : type === "blob" ? statement.columnBlob(index) : null);
      }
      out.push(row);
    }
  } finally { statement.close(); }
  steps.push({ target, call: "$rows", args: [sql], expected: { result: encode(out) } });
};

// Keyed writes and reads.
const G = "g";
const targetTypes = ["none", "record", "object", "vector", "external"];
step("createGraph", [G]);
const nodes = Array.from({ length: 24 }, (_, index) => {
  const targetType = targetTypes[index % targetTypes.length];
  return { graphName: G, nodeId: `n${String(index).padStart(2, "0")}`, kind: index % 3 ? "file" : "dir", targetType,
    ...(targetType === "none" ? {} : { targetNamespace: "ns", targetRef: `ref-${index}` }) };
});
const nodeKeys = step("putGraphNodesKeyed", [nodes]);
const edgeTypes = ["imports", "calls", "contains"];
const edges = [];
for (let index = 0; index < 60; index++) {
  const from = next() % nodes.length;
  let to = next() % nodes.length;
  if (to === from) to = (to + 1) % nodes.length;
  edges.push({ graphName: G, fromNodeId: nodes[from].nodeId, edgeType: edgeTypes[next() % 3], toNodeId: nodes[to].nodeId });
}
edges.push({ ...edges[3] }); // a duplicate in the same batch
const edgeKeys = step("putGraphEdgesKeyed", [edges]);
const missing = 999_999_999n;
step("putGraphNodesKeyed", [[nodes[0], { ...nodes[1], kind: "changed" }]]);
step("getGraphNodesKeyed", [G, [nodeKeys[5], missing, ...nodeKeys.slice(0, 4), nodeKeys[1]]]);
step("getGraphNodesKeyed", [G, BigInt64Array.from(nodeKeys)]);
step("getGraphEdgesKeyed", [G, [...edgeKeys.slice(0, 10), missing, edgeKeys.at(-1)]]);
step("getGraphEdgesKeyed", [G, edgeKeys]);
for (const node of ["n00", "n07", "n13"]) {
  for (const direction of ["outgoing", "incoming"]) {
    step("graphNeighborsKeyed", [{ graphName: G, nodeId: node, direction, limit: 50 }]);
    step("graphNeighborsKeyed", [{ graphName: G, nodeId: node, direction, edgeType: "calls", limit: 2 }]);
  }
}
for (const direction of ["outgoing", "incoming"]) {
  step("graphDegreesKeyed", [{ graphName: G, nodeKeys, direction }]);
  step("graphDegreesKeyed", [{ graphName: G, nodeKeys: [...nodeKeys, missing], direction, edgeType: "imports" }]);
}

// Edge payloads.
step("getGraphEdgePayloads", [G, [...edgeKeys.slice(0, 5), missing]]);
step("replaceGraphEdgePayloads", [G, Array.from(edgeKeys.slice(0, 12), (edgeKey, index) => ({ edgeKey, payload: bytes("w=" + index) }))]);
step("replaceGraphEdgePayloads", [G, [{ edgeKey: edgeKeys[0], payload: new Uint8Array() }, { edgeKey: edgeKeys[1], payload: Uint8Array.of(0, 255, 0) }]]);
step("getGraphEdgePayloads", [G, edgeKeys]);
step("replaceGraphEdgePayloads", [G, [{ edgeKey: edgeKeys[2], payload: bytes("kept?") }, { edgeKey: missing, payload: bytes("x") }]]);
step("getGraphEdgePayloads", [G, edgeKeys.slice(0, 3)]);

// Scans, page by page, continued from the last row of each page.
let nodeAfter;
let edgeAfter;
for (let page = 0; page < 12; page++) {
  const result = step("graphScan", [{ graphName: G, nodeLimit: 7, edgeLimit: 9, ...(nodeAfter ? { nodeAfter } : {}), ...(edgeAfter ? { edgeAfter } : {}) }]);
  const lastNode = result.nodes.at(-1);
  const lastEdge = result.edges.at(-1);
  if (lastNode) nodeAfter = { createdOrder: lastNode.createdOrder, key: lastNode.nodeKey };
  if (lastEdge) edgeAfter = { createdOrder: lastEdge.createdOrder, key: lastEdge.edgeKey };
  if (!result.hasMoreNodes && !result.hasMoreEdges) break;
}

// Directional walks.
for (const startNodeId of ["n00", "n11"]) {
  for (const direction of ["outgoing", "incoming"]) {
    step("graphWalkDirection", [{ graphName: G, startNodeId, direction, maxDepth: 3, limit: 100 }]);
    step("graphWalkDirection", [{ graphName: G, startNodeId, direction, edgeType: "imports", maxDepth: 2, limit: 5 }]);
    step("graphWalkDirectionProfiled", [{ graphName: G, startNodeId, direction, maxDepth: 2, limit: 100 }]);
  }
}

// Core errors.
step("getGraphNodesKeyed", ["no-such-graph", [nodeKeys[0]]]);
step("graphNeighborsKeyed", [{ graphName: G, nodeId: "no-such-node", direction: "outgoing", limit: 5 }]);
step("graphDegreesKeyed", [{ graphName: "no-such-graph", nodeKeys: [nodeKeys[0]], direction: "outgoing" }]);
step("graphScan", [{ graphName: "no-such-graph", nodeLimit: 1, edgeLimit: 1 }]);
step("graphWalkDirection", [{ graphName: G, startNodeId: "no-such-node", direction: "outgoing", maxDepth: 1, limit: 1 }]);
step("putGraphEdgesKeyed", [[{ graphName: G, fromNodeId: "n00", edgeType: "calls", toNodeId: "no-such-node" }]]);

// Fresh graph builders.
const freshNodes = Array.from({ length: 10 }, (_, index) => ({ nodeId: `f${index}`, kind: index % 2 ? "file" : "dir",
  targetType: index % 4 ? "none" : "external", ...(index % 4 ? {} : { targetNamespace: "url", targetRef: `https://example.test/${index}` }) }));
const freshEdges = Array.from({ length: 25 }, () => ({ fromNodeOrdinal: next() % 10, edgeType: edgeTypes[next() % 3], toNodeOrdinal: next() % 10 }));
step("$memory", [], { store: "normalized" });
const normalized = step("buildFreshGraphKeyed", ["fresh", freshNodes, [...freshEdges, freshEdges[0]]], { target: "normalized" });
step("getGraphEdgesKeyed", ["fresh", normalized.edgeKeys], { target: "normalized" });
step("buildFreshGraphKeyed", ["again", freshNodes, freshEdges], { target: "normalized" });
const unique = [...new Map(freshEdges.map(edge => [`${edge.fromNodeOrdinal} ${edge.edgeType} ${edge.toNodeOrdinal}`, edge])).values()];
step("$memory", [], { store: "prepared" });
const prepared = step("buildFreshGraphPreparedKeyed", ["fresh", freshNodes, unique], { target: "prepared" });
step("getGraphEdgesKeyed", ["fresh", prepared.edgeKeys], { target: "prepared" });
step("graphWalkDirection", [{ graphName: "fresh", startNodeId: "f0", direction: "outgoing", maxDepth: 3, limit: 100 }], { target: "prepared" });
step("$memory", [], { store: "payloads" });
const weighted = step("buildFreshGraphPreparedKeyedWithPayloads", ["fresh", freshNodes,
  unique.map((edge, index) => index % 3 ? { ...edge, payload: bytes(`p${index}`) } : edge)], { target: "payloads" });
step("getGraphEdgePayloads", ["fresh", weighted.edgeKeys], { target: "payloads" });
step("graphScan", [{ graphName: "fresh", nodeLimit: 100, edgeLimit: 100 }], { target: "payloads" });
// Rejected builds leave the graph store empty, so they share one database.
step("$memory", [], { store: "rejected" });
step("buildFreshGraphKeyed", ["fresh", freshNodes, [{ fromNodeOrdinal: 0, edgeType: "calls", toNodeOrdinal: 10 }]], { target: "rejected" });
step("buildFreshGraphPreparedKeyed", ["fresh", freshNodes, [unique[0], unique[0]]], { target: "rejected" });
step("buildFreshGraphPreparedKeyedWithPayloads", ["fresh", freshNodes, [{ ...unique[0], toNodeOrdinal: 10 }]], { target: "rejected" });
step("buildFreshGraphKeyed", ["fresh", freshNodes.slice(0, 2), []], { target: "rejected" });

// A fresh-build session over every target.
step("$memory", [], { store: "session" });
for (const sql of setup) step("exec", [sql], { target: "session" });
step("createVectorCollection", ["embeddings", { dimensions: 2, metric: "l2", elementType: "f32" }], { target: "session" });
step("beginFreshBuild", [], { target: "session", store: "build" });
step("tableRows", ["files", ["id", "path", "size", "body"], [
  [1n, "a.rs", 1.5, Uint8Array.of(0, 97)], [2n, "b.rs", null, Uint8Array.of(98)], [3n, "c.rs", -0.25, null],
]], { target: "build" });
step("ftsRows", ["bodies", ["body"], [["fn main"], ["struct Point"], ["fn helper"]]], { target: "build" });
step("graph", ["session", freshNodes.slice(0, 4), [
  { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1, payload: Uint8Array.of(119) },
  { fromNodeOrdinal: 1, edgeType: "imports", toNodeOrdinal: 2 },
  { fromNodeOrdinal: 3, edgeType: "calls", toNodeOrdinal: 0, payload: bytes("w=3") },
]], { target: "build" });
step("vectors", ["embeddings", [{ id: "a.rs", values: Float32Array.of(1, 0) }, { id: "b.rs", values: Float32Array.of(0.5, -2) }]], { target: "build" });
const session = step("finish", [], { target: "build" });
rows("session", "select id, path, size, body from files order by id");
rows("session", "select rowid, body from bodies where bodies match 'fn' order by rowid");
step("getGraphEdgesKeyed", ["session", session.edgeKeys], { target: "session" });
step("getGraphEdgePayloads", ["session", session.edgeKeys], { target: "session" });
step("getVector", ["embeddings", "b.rs"], { target: "session" });
step("$memory", [], { store: "failedSession" });
for (const sql of setup) step("exec", [sql], { target: "failedSession" });
step("beginFreshBuild", [], { target: "failedSession", store: "failed" });
step("tableRows", ["files", ["id", "path"], [[4n, "d.rs"]]], { target: "failed" });
step("tableRows", ["missing_table", ["id"], [[1n]]], { target: "failed" });
step("ftsRows", ["bodies", ["body"], [["late"]]], { target: "failed" });
step("close", [], { target: "failed" });
rows("failedSession", "select count(*) from files");

// Multi-vector i8 search.
step("createVectorCollection", ["codes", { dimensions: 4, metric: "cosine", elementType: "i8" }]);
const codes = Array.from({ length: 30 }, (_, index) => ({ id: `c${String(index).padStart(2, "0")}`,
  values: Int8Array.from({ length: 4 }, () => next() % 256 - 128) }));
step("putVectors", ["codes", codes]);
const queryValues = Int8Array.from({ length: 12 }, () => next() % 256 - 128);
for (const options of [
  { queryCount: 3, limit: 10 },
  { queryCount: 3, limit: 30, candidateIds: ["c03", "c07", "c11", "missing"] },
  { queryCount: 3, limit: 5, mode: "cbm-prefilter-min-cosine", aggregation: "min-cosine", prefilterQueryIndex: 1, prefilterLimit: 8 },
  { queryCount: 1, limit: 4 },
  { queryCount: 3, limit: 5, mode: "cbm-prefilter-min-cosine", prefilterQueryIndex: 3, prefilterLimit: 8 },
]) step("searchVectorsMultiI8", ["codes", { queryValues: queryValues.slice(0, options.queryCount * 4), dimensions: 4, ...options }]);
for (const name of ["db", "normalized", "prepared", "payloads", "rejected", "session", "failedSession"]) targets[name].close();

const output = new URL("../tests/graph-fixture.json", import.meta.url);
writeFileSync(output, JSON.stringify({ generatedBy: `zova-js ${zova.abiVersion}`, setup, steps }) + "\n");
console.log(`wrote ${steps.length} steps to ${output.pathname}`);
