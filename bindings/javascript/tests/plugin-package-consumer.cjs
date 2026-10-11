const assert = require("node:assert/strict");
const { mkdtempSync, rmSync } = require("node:fs");
const { join } = require("node:path");
const { tmpdir } = require("node:os");
const { createRequire } = require("node:module");
// Resolve the installed tarball from the consumer directory, not this source tree.
const { Database, AsyncDatabase } = createRequire(join(process.cwd(), "package.json"))("zova-js");

async function main() {
  const directory = mkdtempSync(join(tmpdir(), "zova-package-plugin-"));
  const extensions = { bundlePaths: [process.env.ZOVA_TEST_PLUGIN_BUNDLE], trustStorePath: process.env.ZOVA_TEST_PLUGIN_TRUST_STORE };
  try {
    const path = join(directory, "plugin.zova");
    const db = Database.create(path, extensions);
    db.installExtension("c_test");
    const stmt = db.prepare("SELECT zova_c_test_cached()");
    assert.equal(stmt.step(), "row");
    assert.equal(stmt.columnInteger(0), 42n);
    stmt.close();
    db.close();
    assert.throws(() => Database.open(path));
    const reopened = AsyncDatabase.open(path, { readOnly: true, extensions });
    await reopened.exec("SELECT zova_c_test_cached()");
    await reopened.close();
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
