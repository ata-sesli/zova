import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

function database(): Database {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-vectors-"));
  temporaryDirectories.push(directory);
  return Database.create(join(directory, "vectors.zova"));
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("vectors", () => {
  test("supports f32 collection lifecycle, batch upsert, and exact search", () => {
    const db = database();
    db.createVectorCollection("documents", {
      dimensions: 3,
      metric: "cosine",
      elementType: "f32",
    });

    expect(db.hasVectorCollection("documents")).toBe(true);
    expect(db.vectorCollectionInfo("documents")).toEqual({
      name: "documents",
      dimensions: 3,
      metric: "cosine",
      elementType: "f32",
      vectorCount: 0n,
    });

    db.putVectors("documents", [
      { id: "north", values: new Float32Array([1, 0, 0]) },
      { id: "east", values: new Float32Array([0, 1, 0]) },
      { id: "near-north", values: new Float32Array([0.9, 0.1, 0]) },
    ]);
    db.putVector("documents", "east", new Float32Array([0, 0.8, 0.2]));

    const vector = db.getVector("documents", "east");
    expect(vector.id).toBe("east");
    expect(vector.values).toBeInstanceOf(Float32Array);
    expect(vector.values).toEqual(new Float32Array([0, 0.8, 0.2]));
    expect(db.hasVector("documents", "east")).toBe(true);

    expect(
      db.searchVectors("documents", new Float32Array([1, 0, 0]), {
        limit: 2,
      }).map((result) => result.id),
    ).toEqual(["north", "near-north"]);
    expect(
      db.searchVectors("documents", new Float32Array([1, 0, 0]), {
        candidateIds: ["east", "near-north"],
        limit: 2,
      }).map((result) => result.id),
    ).toEqual(["near-north", "east"]);
    expect(
      db.searchVectorsById("documents", "north", {
        maxDistance: 0.01,
        limit: 10,
      }).map((result) => result.id),
    ).toEqual(["near-north"]);

    db.deleteVector("documents", "east");
    expect(db.hasVector("documents", "east")).toBe(false);
    db.putVectors("documents", [
      { id: "west", values: new Float32Array([-1, 0, 0]) },
      { id: "south", values: new Float32Array([0, -1, 0]) },
    ]);
    db.deleteVectors("documents", ["north", "missing", "west"]);
    expect(db.hasVector("documents", "north")).toBe(false);
    expect(db.hasVector("documents", "west")).toBe(false);
    expect(db.hasVector("documents", "south")).toBe(true);
    expect(db.listVectorCollections()).toHaveLength(1);
    db.deleteVectorCollection("documents");
    expect(db.hasVectorCollection("documents")).toBe(false);
    db.close();
  });

  test("round-trips f16 and i8 through their original typed arrays", () => {
    const db = database();
    db.createVectorCollection("half", {
      dimensions: 2,
      metric: "l2",
      elementType: "f16",
    });
    db.createVectorCollection("quantized", {
      dimensions: 3,
      metric: "dot",
      elementType: "i8",
    });

    db.putVector("half", "one", new Uint16Array([0x3c00, 0x4000]));
    db.putVector("quantized", "one", new Int8Array([-4, 0, 7]));

    expect(db.getVector("half", "one").values).toEqual(
      new Uint16Array([0x3c00, 0x4000]),
    );
    expect(db.getVector("quantized", "one").values).toEqual(
      new Int8Array([-4, 0, 7]),
    );
    db.close();
  });

  test("dimension and element-type errors retain Zova status", () => {
    const db = database();
    db.createVectorCollection("documents", {
      dimensions: 3,
      metric: "cosine",
      elementType: "f32",
    });

    expect(() =>
      db.putVector("documents", "bad", new Float32Array([1, 2])),
    ).toThrow(ZovaError);
    expect(() =>
      db.putVector("documents", "bad", new Int8Array([1, 2, 3])),
    ).toThrow(ZovaError);
    db.close();
  });
});
