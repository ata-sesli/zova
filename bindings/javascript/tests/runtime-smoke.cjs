const assert = require("node:assert/strict");

const {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} = require("../dist/index.js");

assert.equal(packageVersion, "1.0.0-rc.1");
assert.equal(abiVersion, "1.0.0-rc.1");
assert.equal(formatVersion, "11");
assert.equal(sqliteVersion, "3.53.4");
