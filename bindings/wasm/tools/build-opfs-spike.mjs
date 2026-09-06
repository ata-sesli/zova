// Private #64 harness. Upstream glue wraps the same SQLite linked with Zova.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
if (process.argv.length !== 5) throw new Error("usage: build-opfs-spike.mjs <sqlite-source> <output> <existing-wasm-core-output>");
const [source, output, core] = process.argv.slice(2).map(x => resolve(x));
const root = resolve(import.meta.dir, "../../..");
mkdirSync(output, { recursive: true });
const wasm = join(source, "ext/wasm");
const run = (args) => {
  const result = Bun.spawnSync(args, { stdout: "inherit", stderr: "inherit" });
  if (result.exitCode !== 0) throw new Error(`Command failed: ${args[0]}`);
};
const sqlite = join(root, "vendor/sqlite3.53.4");
const sourceId = readFileSync(join(source, "manifest.uuid"), "utf8").trim();
if (readFileSync(join(source, "VERSION"), "utf8").trim() !== "3.53.4" ||
    !readFileSync(join(sqlite, "sqlite3.h"), "utf8").includes(sourceId) || sourceId.length !== 64)
  throw new Error("SQLite adapter source must match the bundled 3.53.4 source ID");
const emcc = process.env.EMCC || "emcc";
if (Bun.spawnSync([emcc,"-dumpversion"]).stdout.toString().trim().replace(/-git$/, "") !==
    readFileSync(join(root,"bindings/wasm/emscripten-version.txt"),"utf8").trim()) throw new Error("Pinned Emscripten required");
run(["cc", "-O0", join(wasm, "libcmpp.c"), join(sqlite, "sqlite3.c"), "-I" + sqlite,
  "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_THREADSAFE=0", '-DCMPP_DEFAULT_DELIM="//#"',
  "-DCMPP_MAIN", "-DCMPP_OMIT_D_MODULE", "-DCMPP_OMIT_D_PIPE", "-o", join(output, "c-pp")]);
const inputs = ["api/sqlite3-api-prologue.js", "common/whwasmutil.js", "jaccwabyt/jaccwabyt.js",
  "api/sqlite3-api-glue.c-pp.js", "api/sqlite3-vfs-helper.c-pp.js", "api/sqlite3-vfs-opfs-sahpool.c-pp.js"];
let glue = "Module.zovaOpfsBootstrap = async function() {\n";
for (const [index, input] of inputs.entries()) {
  const dest = join(output, `glue-${index}.js`);
  run([join(output, "c-pp"), "-o", dest, "-Dtarget=esm", join(wasm, input)]);
  glue += readFileSync(dest, "utf8") + "\n";
}
glue += "return globalThis.sqlite3ApiBootstrap({exports: wasmExports, memory: wasmMemory});\n};\n";
writeFileSync(join(output, "post.js"), glue);
run([join(output, "c-pp"), "-Dbare-bones", "-o", join(output, "exports.txt"), join(wasm, "api/EXPORTED_FUNCTIONS.c-pp")]);
const exports = readFileSync(join(output, "exports.txt"), "utf8").split(/\s+/).filter(Boolean);
writeFileSync(join(output, "exports.json"), JSON.stringify(exports));
const env = Bun.spawnSync(["zig", "env"], { stdout: "pipe" });
const zigLib = env.stdout.toString().match(/\.lib_dir = "([^"]+)"/)[1];
run(["zig", "build-lib", "-ofmt=c", "-O", "ReleaseSafe", "-target", "wasm32-emscripten", "-fsingle-threaded",
  "-I" + sqlite, "-lc", "-femit-bin=" + join(output,"zova_c.c"),
  "--cache-dir", join(core,"zig-cache"), "--global-cache-dir", join(core,"zig-global-cache"),
  "--dep", "zova", "-Mroot=" + join(root,"bindings/wasm/tests/opfs-root.zig"),
  "-I" + sqlite, "--dep", "zova_build_options", "-Mzova=" + join(root,"src/c_api.zig"),
  "-Mzova_build_options=" + join(root,"bindings/wasm/tests/opfs-build-options.zig")]);
run([emcc, "-O2", "-I" + zigLib, "-I" + join(root, "include"), "-I" + sqlite,
  "-Wno-incompatible-pointer-types", "-DSQLITE_THREADSAFE=0", "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_DBSTAT_VTAB",
  "-DSQLITE_DEFAULT_PAGE_SIZE=4096",
  join(output, "zova_c.c"), join(wasm, "api/sqlite3-wasm.c"), join(root, "bindings/wasm/tests/opfs-smoke.c"),
  join(root,"bindings/wasm/native/smoke.c"),
  "--no-entry", "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sENVIRONMENT=worker", "-sALLOW_MEMORY_GROWTH=1",
  "-sALLOW_TABLE_GROWTH=1", "-sEXPORTED_FUNCTIONS=" + JSON.stringify([...exports,"_zova_wasm_smoke"]),
  "--post-js", join(output, "post.js"), "-o", join(output, "zova.mjs")]);
