import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AsyncDatabase, Database } from "../js/index.js";

test("plugin selection rejects invalid bundle before mutation", () => {
  const dir = mkdtempSync(join(tmpdir(), "zova-plugin-invalid-"));
  try {
    const path = join(dir, "invalid.zova");
    expect(() => Database.create(path, { bundlePaths: ["bad\0.zovaext"] })).toThrow();
    expect(existsSync(path)).toBe(false);
    expect(() => AsyncDatabase.create(path, { bundlePaths: ["bad\0.zovaext"] })).toThrow();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

const packageTest = process.env.ZOVA_TEST_PLUGIN_BUNDLE ? test : test.skip;
packageTest("portable plugin selection works through sync and async handles", async () => {
  const dir = mkdtempSync(join(tmpdir(), "zova-plugin-package-"));
  const extensions = { bundlePaths: [process.env.ZOVA_TEST_PLUGIN_BUNDLE!], trustStorePath: process.env.ZOVA_TEST_PLUGIN_TRUST_STORE! };
  try {
    const path = join(dir, "plugin.zova");
    const db = Database.create(path, extensions);
    db.installExtension("c_test");
    const stmt = db.prepare("SELECT zova_c_test_cached()");
    expect(stmt.step()).toBe("row");
    expect(stmt.columnInteger(0)).toBe(42n);
    expect(() => db.close()).toThrow();
    stmt.close();
    db.close();
    expect(() => Database.open(path)).toThrow();
    const read = Database.open(path, { readOnly: true, extensions });
    read.checkExtension("c_test");
    read.close();
    const asyncDb = AsyncDatabase.open(path, { readOnly: true, extensions });
    await asyncDb.exec("SELECT zova_c_test_cached()");
    await asyncDb.close();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
