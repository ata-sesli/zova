import assert from "node:assert/strict";

import {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} from "../dist/index.js";

assert.equal(packageVersion, "1.0.0-rc.2");
assert.equal(abiVersion, "1.0.0-rc.2");
assert.equal(formatVersion, "11");
assert.equal(sqliteVersion, "3.53.4");
