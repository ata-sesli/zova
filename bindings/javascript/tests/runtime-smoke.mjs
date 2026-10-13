import assert from "node:assert/strict";

import {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} from "../dist/index.js";

assert.equal(packageVersion, "1.3.0");
assert.equal(abiVersion, "1.3.0");
assert.equal(formatVersion, "12");
assert.equal(sqliteVersion, "3.53.4");
