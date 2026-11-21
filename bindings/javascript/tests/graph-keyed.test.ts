import { describe, expect, test } from "bun:test";

import { Database, ZovaError } from "../js/index.js";
import type { GraphFreshNodeInput, GraphNodeInput } from "../js/index.js";

const G = "code";

function node(nodeId: string, kind = "file"): GraphNodeInput {
  return { graphName: G, nodeId, kind, targetType: "none" };
}

function edge(fromNodeId: string, edgeType: string, toNodeId: string) {
  return { graphName: G, fromNodeId, edgeType, toNodeId };
}

function freshNode(nodeId: string): GraphFreshNodeInput {
  return { nodeId, kind: "file", targetType: "none" };
}

describe("keyed graphs", () => {
  test("keyed CRUD, payloads, degrees, and scans", () => {
    const db = Database.createMemory();
    db.createGraph(G);
    const nodeKeys = db.putGraphNodesKeyed([node("a"), node("b", "dir")]);
    expect(nodeKeys).toBeInstanceOf(BigInt64Array);
    expect(nodeKeys.length).toBe(2);
    const edgeKeys = db.putGraphEdgesKeyed([edge("a", "imports", "b")]);
    expect(edgeKeys.length).toBe(1);

    const nodes = db.getGraphNodesKeyed(G, [nodeKeys[1], 999_999n, nodeKeys[0]]);
    expect(nodes[0]).toMatchObject({ nodeId: "b", kind: "dir", nodeKey: nodeKeys[1] });
    expect(nodes[1]).toBeNull();
    expect(nodes[2]?.nodeId).toBe("a");

    const [found, missing] = db.getGraphEdgesKeyed(G, BigInt64Array.of(edgeKeys[0], 999_999n));
    expect(missing).toBeNull();
    expect(found).toMatchObject({
      sourceNodeKey: nodeKeys[0],
      edgeType: "imports",
      targetNodeKey: nodeKeys[1],
    });

    expect(
      db.graphNeighborsKeyed({ graphName: G, nodeId: "a", direction: "outgoing", limit: 10 }),
    ).toEqual([
      { edgeKey: edgeKeys[0], neighborNodeKey: nodeKeys[1], nodeId: "b", kind: "dir", edgeType: "imports" },
    ]);
    expect([...db.graphDegreesKeyed({ graphName: G, nodeKeys, direction: "outgoing" })]).toEqual([1n, 0n]);
    expect([
      ...db.graphDegreesKeyed({ graphName: G, nodeKeys, direction: "incoming", edgeType: "imports" }),
    ]).toEqual([0n, 1n]);

    expect(db.getGraphEdgePayloads(G, [edgeKeys[0], 999_999n])).toEqual([new Uint8Array(), null]);
    db.replaceGraphEdgePayloads(G, [{ edgeKey: edgeKeys[0], payload: Uint8Array.of(0, 7) }]);
    expect(db.getGraphEdgePayloads(G, edgeKeys)).toEqual([Uint8Array.of(0, 7)]);
    expect(() => db.getGraphNodesKeyed(G, [1n << 70n])).toThrow("signed 64-bit");

    const first = db.graphScan({ graphName: G, nodeLimit: 1, edgeLimit: 5 });
    expect(first.nodes.map((item) => item.nodeId)).toEqual(["a"]);
    expect(first.hasMoreNodes).toBe(true);
    expect(first.edges.length).toBe(1);
    expect(first.hasMoreEdges).toBe(false);
    const lastNode = first.nodes[0];
    const lastEdge = first.edges[0];
    const second = db.graphScan({
      graphName: G,
      nodeLimit: 5,
      edgeLimit: 5,
      nodeAfter: { createdOrder: lastNode.createdOrder, key: lastNode.nodeKey },
      edgeAfter: { createdOrder: lastEdge.createdOrder, key: lastEdge.edgeKey },
    });
    expect(second.nodes.map((item) => item.nodeId)).toEqual(["b"]);
    expect(second.hasMoreNodes).toBe(false);
    expect(second.edges).toEqual([]);
    db.close();
  });

  test("directional walks", () => {
    const db = Database.createMemory();
    db.createGraph(G);
    db.putGraphNodes([node("a"), node("b"), node("c")]);
    db.putGraphEdges([edge("a", "imports", "b"), edge("b", "imports", "c")]);

    const items = db.graphWalkDirection({
      graphName: G,
      startNodeId: "c",
      direction: "incoming",
      maxDepth: 2,
      limit: 10,
    });
    expect(items.map((item) => [item.nodeId, item.depth])).toEqual([["c", 0], ["b", 1], ["a", 2]]);

    const profiled = db.graphWalkDirectionProfiled({
      graphName: G,
      startNodeId: "a",
      direction: "outgoing",
      edgeType: "imports",
      maxDepth: 1,
      limit: 10,
    });
    expect(profiled.items.map((item) => item.nodeId)).toEqual(["a", "b"]);
    expect(profiled.profile.resultCount).toBe(2);
    expect(profiled.profile.totalProfiledMs).toBeGreaterThanOrEqual(0);

    expect(() =>
      db.graphWalkDirection({
        graphName: G,
        startNodeId: "a",
        direction: "sideways" as "outgoing",
        maxDepth: 1,
        limit: 1,
      }),
    ).toThrow(ZovaError);
    db.close();
  });

  test("fresh graph builders", () => {
    const nodes = [freshNode("a"), freshNode("b")];
    let db = Database.createMemory();
    const merged = db.buildFreshGraphKeyed(G, nodes, [
      { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1 },
      { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1 },
    ]);
    expect(merged.nodeKeys.length).toBe(2);
    // The normalizing builder merges duplicate edges; both inputs share a key.
    expect(merged.edgeKeys.length).toBe(2);
    expect(merged.edgeKeys[0]).toBe(merged.edgeKeys[1]);
    expect(db.graphInfo(G).edgeCount).toBe(1n);
    db.close();

    db = Database.createMemory();
    expect(() =>
      db.buildFreshGraphPreparedKeyed(G, nodes, [
        { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1, payload: Uint8Array.of(1) },
      ]),
    ).toThrow(ZovaError);
    const prepared = db.buildFreshGraphPreparedKeyed(G, nodes, [
      { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1 },
    ]);
    expect(db.getGraphEdgesKeyed(G, prepared.edgeKeys)[0]?.targetNodeKey).toBe(prepared.nodeKeys[1]);
    db.close();

    db = Database.createMemory();
    const withPayloads = db.buildFreshGraphPreparedKeyedWithPayloads(G, nodes, [
      { fromNodeOrdinal: 0, edgeType: "imports", toNodeOrdinal: 1, payload: new TextEncoder().encode("w=1") },
    ]);
    expect(db.getGraphEdgePayloads(G, withPayloads.edgeKeys)).toEqual([new TextEncoder().encode("w=1")]);
    db.close();
  });
});

describe("multi-vector i8 search", () => {
  test("scores each vector by its least similar query row", () => {
    const db = Database.createMemory();
    db.createVectorCollection("codes", { dimensions: 2, metric: "cosine", elementType: "i8" });
    db.putVectors("codes", [
      { id: "east", values: Int8Array.of(100, 0) },
      { id: "north", values: Int8Array.of(0, 100) },
      { id: "diag", values: Int8Array.of(70, 70) },
    ]);
    const queryValues = Int8Array.of(100, 0, 0, 100);

    const results = db.searchVectorsMultiI8("codes", { queryValues, queryCount: 2, dimensions: 2, limit: 3 });
    expect(results[0].id).toBe("diag");
    expect(new Set(results.map((result) => result.id))).toEqual(new Set(["diag", "east", "north"]));

    const within = db.searchVectorsMultiI8("codes", {
      queryValues,
      queryCount: 2,
      dimensions: 2,
      limit: 3,
      candidateIds: ["east", "north"],
    });
    expect(new Set(within.map((result) => result.id))).toEqual(new Set(["east", "north"]));

    const prefiltered = db.searchVectorsMultiI8("codes", {
      queryValues,
      queryCount: 2,
      dimensions: 2,
      limit: 1,
      mode: "cbm-prefilter-min-cosine",
      aggregation: "min-cosine",
      prefilterQueryIndex: 0,
      prefilterLimit: 2,
    });
    expect(prefiltered.length).toBe(1);

    expect(() =>
      db.searchVectorsMultiI8("codes", {
        queryValues,
        queryCount: 2,
        dimensions: 2,
        limit: 1,
        mode: "nearest" as "global-min-cosine",
      }),
    ).toThrow(ZovaError);
    db.close();
  });
});
