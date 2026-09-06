import { existsSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { createHash } from "node:crypto";
const output = resolve(process.argv[2]);
mkdirSync(output,{recursive:true});
const archive = join(output,"sqlite-3.53.4.tar.gz");
const digest = "16bc1b2027ba2653e3d262e740376be23f67cad77865db814493267494326c3c";
if (!existsSync(archive)) {
  const response = await fetch("https://github.com/sqlite/sqlite/archive/refs/tags/version-3.53.4.tar.gz");
  if (!response.ok) throw new Error(`SQLite source download failed: ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (createHash("sha256").update(bytes).digest("hex") !== digest) throw new Error("SQLite archive checksum mismatch");
  await Bun.write(archive,bytes);
}
if (createHash("sha256").update(new Uint8Array(await Bun.file(archive).arrayBuffer())).digest("hex") !== digest) throw new Error("SQLite archive checksum mismatch");
const source = join(output,"sqlite-version-3.53.4");
if (!existsSync(source)) {
  const result = Bun.spawnSync(["tar","-xzf",archive,"-C",output],{stdout:"inherit",stderr:"inherit"});
  if(result.exitCode) throw new Error("SQLite extraction failed");
}
console.log(source);
