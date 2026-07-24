import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

function database(): { database: Database; path: string } {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-graphs-"));
  temporaryDirectories.push(directory);
  const path = join(directory, "graphs.zova");
  return { database: Database.create(path), path };
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("graphs", () => {
  test("supports lifecycle, atomic batches, metadata, traversal, and ordering", () => {
    const { database: db } = database();
    db.createGraph("knowledge");
    expect(db.hasGraph("knowledge")).toBe(true);

    db.putGraphNodes([
      {
        graphName: "knowledge",
        nodeId: "root",
        kind: "document",
        targetType: "record",
        targetNamespace: "documents",
        targetRef: "1",
      },
      {
        graphName: "knowledge",
        nodeId: "beta",
        kind: "section",
        targetType: "none",
      },
      {
        graphName: "knowledge",
        nodeId: "alpha",
        kind: "section",
        targetType: "object",
        targetRef: "aabb",
      },
    ]);
    db.putGraphEdges([
      {
        graphName: "knowledge",
        fromNodeId: "root",
        edgeType: "contains",
        toNodeId: "beta",
      },
      {
        graphName: "knowledge",
        fromNodeId: "root",
        edgeType: "contains",
        toNodeId: "alpha",
      },
      {
        graphName: "knowledge",
        fromNodeId: "alpha",
        edgeType: "next",
        toNodeId: "beta",
      },
      {
        graphName: "knowledge",
        fromNodeId: "root",
        edgeType: "contains",
        toNodeId: "alpha",
      },
    ]);

    expect(db.graphInfo("knowledge")).toEqual({
      name: "knowledge",
      nodeCount: 3n,
      edgeCount: 3n,
    });
    expect(db.getGraphNode("knowledge", "root")).toEqual({
      graphName: "knowledge",
      nodeId: "root",
      kind: "document",
      targetType: "record",
      targetNamespace: "documents",
      targetRef: "1",
    });
    expect(db.hasGraphNode("knowledge", "missing")).toBe(false);
    expect(
      db.graphNeighbors({
        graphName: "knowledge",
        nodeId: "root",
        direction: "outgoing",
        limit: 10,
      }).map((neighbor) => neighbor.nodeId),
    ).toEqual(["beta", "alpha"]);
    expect(
      db.graphNeighbors({
        graphName: "knowledge",
        nodeId: "beta",
        direction: "incoming",
        edgeType: "contains",
        limit: 10,
      }),
    ).toEqual([
      { nodeId: "root", kind: "document", edgeType: "contains" },
    ]);
    expect(
      db.graphDegree({
        graphName: "knowledge",
        nodeId: "root",
        direction: "outgoing",
      }),
    ).toBe(2n);
    expect(
      db.graphWalk({
        graphName: "knowledge",
        startNodeId: "root",
        maxDepth: 2,
        limit: 10,
      }).map((item) => [item.nodeId, item.depth]),
    ).toEqual([
      ["root", 0],
      ["beta", 1],
      ["alpha", 1],
    ]);
    expect(
      db.getGraphEdge("knowledge", "root", "contains", "alpha"),
    ).toEqual({
      graphName: "knowledge",
      fromNodeId: "root",
      edgeType: "contains",
      toNodeId: "alpha",
    });

    db.deleteGraphEdges([
      {
        graphName: "knowledge",
        fromNodeId: "root",
        edgeType: "contains",
        toNodeId: "alpha",
      },
    ]);
    db.deleteGraphNodes("knowledge", ["alpha"]);
    expect(db.graphInfo("knowledge")).toEqual({
      name: "knowledge",
      nodeCount: 2n,
      edgeCount: 1n,
    });
    expect(db.listGraphs()).toHaveLength(1);
    db.deleteGraph("knowledge");
    expect(db.hasGraph("knowledge")).toBe(false);
    db.close();
  });

  test("rejects a missing endpoint without partially mutating a batch", () => {
    const { database: db } = database();
    db.createGraph("knowledge");
    db.putGraphNodes([
      {
        graphName: "knowledge",
        nodeId: "root",
        kind: "document",
        targetType: "none",
      },
      {
        graphName: "knowledge",
        nodeId: "child",
        kind: "section",
        targetType: "none",
      },
    ]);

    expect(() =>
      db.putGraphEdges([
        {
          graphName: "knowledge",
          fromNodeId: "root",
          edgeType: "contains",
          toNodeId: "child",
        },
        {
          graphName: "knowledge",
          fromNodeId: "root",
          edgeType: "contains",
          toNodeId: "missing",
        },
      ]),
    ).toThrow(ZovaError);
    expect(db.graphInfo("knowledge").edgeCount).toBe(0n);
    db.close();
  });

  test("graph mutations participate in caller transactions and survive reopen", () => {
    const { database: db, path } = database();
    db.createGraph("knowledge");
    db.begin();
    db.putGraphNode({
      graphName: "knowledge",
      nodeId: "rolled-back",
      kind: "document",
      targetType: "none",
    });
    db.rollback();
    expect(db.hasGraphNode("knowledge", "rolled-back")).toBe(false);

    db.putGraphNode({
      graphName: "knowledge",
      nodeId: "kept",
      kind: "document",
      targetType: "none",
    });
    db.close();

    const reopened = Database.open(path);
    expect(reopened.hasGraphNode("knowledge", "kept")).toBe(true);
    reopened.close();
  });
});
