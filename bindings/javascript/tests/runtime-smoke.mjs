import assert from "node:assert/strict";

import {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} from "../dist/index.js";

assert.equal(packageVersion, "0.26.1");
assert.equal(abiVersion, "0.26.1");
assert.equal(formatVersion, "11");
assert.equal(sqliteVersion, "3.53.2");
