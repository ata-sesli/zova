const assert = require("node:assert/strict");
const { join } = require("node:path");
const { createRequire } = require("node:module");
const { Database } = createRequire(join(process.cwd(), "package.json"))("zova-js");
const db = Database.open(process.env.ZOVA_USEARCH_DATABASE, { readOnly: true,
  extensions: { bundlePaths: [process.env.ZOVA_USEARCH_BUNDLE], trustStorePath: process.env.ZOVA_USEARCH_TRUST } });
const statement = db.prepare("SELECT vector_id,distance FROM zova_usearch_search('points',x'0000000000000000',2,64)");
try {
  const rows = [];
  while (statement.step() === "row") rows.push([statement.columnText(0), statement.columnFloat(1)]);
  assert.deepEqual(rows, [["one", 1], ["two", 2]]);
} finally { statement.close(); db.close(); }
console.log("installed JavaScript USearch consumer: ok");
