// Read-only validation of the actual npm archive, not a source-directory check.
const [archive] = process.argv.slice(2);
if (!archive) throw new Error("usage: bun check-package.mjs <tarball>");
function tar(...args) {
  const result = Bun.spawnSync(["tar", ...args], { stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  return result.stdout.toString();
}
const files = tar("-tzf", archive).trim().split("\n");
const allowed = /^package\/(?:package.json|README.md|LICENSE|zova\.(?:mjs|wasm)|dist\/(?:index\.(?:js|d.ts)|(?:channel|runtime|worker)\.(?:mjs|d.mts)))$/;
for (const file of files) {
  if (!allowed.test(file)) throw new Error(`Unexpected package file: ${file}`);
}
for (const required of ["package.json", "dist/index.js", "dist/index.d.ts", "dist/worker.mjs", "dist/runtime.mjs", "dist/channel.mjs", "zova.mjs", "zova.wasm", "LICENSE", "README.md"]) {
  if (!files.includes(`package/${required}`)) throw new Error(`Missing ${required}`);
}
const metadata = JSON.parse(tar("-xOf", archive, "package/package.json"));
if (metadata.name !== "zova-wasm" || metadata.type !== "module") throw new Error("Wrong package identity");
if (metadata.dependencies || metadata.optionalDependencies) throw new Error("Unexpected runtime dependency");
if (metadata.exports["."].browser !== "./dist/index.js" || metadata.exports["."].require) throw new Error("Expected browser ESM export");
for (const file of files.filter(path => /\.(?:js|mjs|ts|mts)$/.test(path))) {
  if (/\/Users\/|\/Volumes\/|sourceMappingURL/.test(tar("-xOf", archive, file))) throw new Error(`Local path or source map in ${file}`);
}
console.log(`Package check passed: ${files.length} files`);
