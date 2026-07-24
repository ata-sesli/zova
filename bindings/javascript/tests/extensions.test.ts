import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Database, ZovaError } from "../js/index.js";

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("bundled extensions", () => {
  test("installs, inspects, checks, and drops a bundled extension", () => {
    const directory = mkdtempSync(join(tmpdir(), "zova-javascript-extension-"));
    temporaryDirectories.push(directory);
    const db = Database.create(join(directory, "extensions.zova"));

    db.installExtension("trgm");
    const info = db.extensionInfo("trgm");
    expect(info.name).toBe("trgm");
    expect(info.version.length).toBeGreaterThan(0);
    expect(db.listExtensions().map((item) => item.name)).toEqual(["trgm"]);
    db.checkExtension("trgm");
    db.checkExtensions();
    db.dropExtension("trgm");
    expect(db.listExtensions()).toEqual([]);
    expect(() => db.extensionInfo("trgm")).toThrow(ZovaError);
    db.close();
  });
});
