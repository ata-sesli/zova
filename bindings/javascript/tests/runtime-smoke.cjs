const assert = require("node:assert/strict");

const {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} = require("../dist/index.js");

assert.equal(packageVersion, "0.25.0");
assert.equal(abiVersion, "0.25.0");
assert.equal(formatVersion, "9");
assert.equal(sqliteVersion, "3.53.2");
