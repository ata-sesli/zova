// Records native zova-js filtered vector search results for the browser
// tests: node tools/generate-vector-fixture.mjs <zova-js-directory>
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";

const zovaDirectory = process.argv[2];
if (!zovaDirectory) throw new Error("usage: node tools/generate-vector-fixture.mjs <zova-js-directory>");
const zova = createRequire(import.meta.url)(zovaDirectory);
let state = 12345;
const next = () => { state ^= state << 13; state >>>= 0; state ^= state >>> 17; state ^= state << 5; state >>>= 0; return state; };
const dimensions = 8;
const values = type => Array.from({ length: dimensions }, () => {
  const random = next();
  if (type === "f32") return (random % 2001 - 1000) / 250;
  if (type === "i8") return random % 256 - 128;
  return ((random & 1) << 15) | ((10 + random % 8) << 10) | (random >>> 8) % 1024; // finite half-float bits
});
const typed = (type, items) => type === "f32" ? new Float32Array(items) : type === "f16" ? new Uint16Array(items) : new Int8Array(items);
const run = operation => {
  try { return { results: operation().map(item => [item.id, item.distance]) }; }
  catch (error) { return { error: error.code ?? String(error) }; }
};
const collections = [];
for (const metric of ["cosine", "l2", "dot"]) {
  for (const elementType of ["f32", "f16", "i8"]) {
    const db = zova.Database.createMemory();
    const name = `${metric}-${elementType}`;
    db.createVectorCollection(name, { dimensions, metric, elementType });
    const vectors = Array.from({ length: 40 }, (_, index) => ({ id: `v${String(index).padStart(2, "0")}`, values: values(elementType) }));
    db.putVectors(name, vectors.map(vector => ({ id: vector.id, values: typed(elementType, vector.values) })));
    const query = values(elementType);
    const all = db.searchVectors(name, typed(elementType, query), { limit: 40 });
    const cut = all[Math.floor(all.length / 3)].distance;
    const candidates = ["v03", "v07", "v11", "v19", "v23", "v31", "missing"];
    const optionSets = [
      { limit: 5 },
      { limit: 5, candidateIds: candidates },
      { limit: 3, candidateIds: ["missing", "absent"] },
      { limit: 10, candidateIds: [] },
      { limit: 40, maxDistance: cut },
      { limit: 4, candidateIds: candidates, maxDistance: cut },
      { limit: 5, maxDistance: all[0].distance },
      { limit: 0 },
      { limit: 5, maxDistance: -1 },
      { limit: 5, maxDistance: Number.NaN },
      { limit: 5, candidateIds: ["v03", "v03", "v07"] },
    ];
    const cases = [];
    for (const options of optionSets) {
      cases.push({ by: "query", options, expected: run(() => db.searchVectors(name, typed(elementType, query), options)) });
      cases.push({ by: "v07", options, expected: run(() => db.searchVectorsById(name, "v07", options)) });
    }
    cases.push({ by: "missing", options: { limit: 5, candidateIds: candidates }, expected: run(() => db.searchVectorsById(name, "missing", { limit: 5, candidateIds: candidates })) });
    collections.push({ name, metric, elementType, dimensions, vectors, query, cases });
    db.close();
  }
}
// NaN is not JSON; it is written as the string "NaN" and restored by readers.
const encode = value => JSON.stringify(value, (_, item) => Number.isNaN(item) ? "NaN" : item);
const output = new URL("../tests/vector-fixture.json", import.meta.url);
writeFileSync(output, `{"generatedBy":${JSON.stringify(`zova-js ${zova.packageVersion}`)},"collections":[\n${collections.map(encode).join(",\n")}\n]}\n`);
console.log(`wrote ${collections.length} native collections to ${output.pathname}`);
