const assert = require("node:assert/strict");
const { join } = require("node:path");
const { createRequire } = require("node:module");
const { Database } = createRequire(join(process.cwd(), "package.json"))("zova-js");
const db = Database.open(process.env.ZOVA_PAGERANK_DATABASE, { readOnly: true,
  extensions: { bundlePaths: [process.env.ZOVA_PAGERANK_BUNDLE], trustStorePath: process.env.ZOVA_PAGERANK_TRUST } });
const statement = db.prepare("SELECT node_key,node_id,score FROM zova_networkit_pagerank('cycle',0.85,1e-10,200,10,10)");
try {
  let count = 0, sum = 0;
  while (statement.step() === "row") {
    assert.ok(statement.columnInteger(0) > 0n);
    assert.ok(statement.columnText(1));
    sum += statement.columnFloat(2); count++;
  }
  assert.equal(count, 4); assert.ok(Math.abs(sum - 1) < 1e-10);
} finally { statement.close(); db.close(); }
console.log("installed JavaScript PageRank consumer: ok");
