// Records native zova-js object IDs and manifests for the browser object
// tests: node tools/generate-object-fixture.mjs <zova-js-directory>
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { patternBytes, objectFixtureCases, objectFixtureProfiles, objectWriterPiece } from "../tests/browser-helpers.mjs";

const zovaDirectory = process.argv[2];
if (!zovaDirectory) throw new Error("usage: node tools/generate-object-fixture.mjs <zova-js-directory>");
const zova = createRequire(import.meta.url)(zovaDirectory);
const hex = bytes => Buffer.from(bytes).toString("hex");
const manifest = (db, id) => {
  const value = db.objectManifest(id);
  return { objectId: hex(value.objectId), sizeBytes: String(value.sizeBytes), chunkCount: String(value.chunkCount), chunker: value.chunker,
    chunks: value.chunks.map(chunk => [String(chunk.index), hex(chunk.hash), String(chunk.offset), String(chunk.sizeBytes)]) };
};
const results = [];
for (const testCase of objectFixtureCases) {
  const data = patternBytes(testCase.length, testCase.seed);
  for (const profile of objectFixtureProfiles) {
    const db = zova.Database.createMemory();
    const put = profile === undefined ? db.putObject(data) : db.putObjectWithOptions(data, { profile });
    const writer = profile === undefined ? db.objectWriter() : db.objectWriterWithOptions({ profile });
    for (let offset = 0; offset < data.length; offset += objectWriterPiece) writer.write(data.subarray(offset, offset + objectWriterPiece));
    const written = writer.finish();
    writer.close();
    results.push({ case: testCase.name, profile: profile ?? null, objectId: hex(zova.objectId(data)), chunkId: hex(zova.objectChunkId(data)),
      put: manifest(db, put), writer: manifest(db, written) });
    db.close();
  }
}
const output = new URL("../tests/object-fixture.json", import.meta.url);
// One result per line keeps the fixture reviewable as a diff.
writeFileSync(output, `{"generatedBy":${JSON.stringify(`zova-js ${zova.packageVersion}`)},"results":[\n${results.map(result => JSON.stringify(result)).join(",\n")}\n]}\n`);
console.log(`wrote ${results.length} native results to ${output.pathname}`);
