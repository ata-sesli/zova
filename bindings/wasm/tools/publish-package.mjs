import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { verifyArtifactRun } from "./verify-artifact-run.mjs";

export function publishPackage({ version, artifactRoot, run, jobs, expectedCommit }, npm = args => spawnSync("npm", args, { encoding: "utf8" })) {
  verifyArtifactRun(run, jobs, expectedCommit);
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error("Invalid release version");
  }
  const tag = version.includes("-") ? "next" : "latest";
  const tarball = join(artifactRoot, `zova-${version}-wasm`, `zova-wasm-${version}.tgz`);
  const integrity = `sha512-${createHash("sha512").update(readFileSync(tarball)).digest("base64")}`;
  const existing = npm(["view", `zova-wasm@${version}`, "dist.integrity", "--json"]);
  if (existing.error) throw existing.error;
  if (existing.status === 0) {
    if (JSON.parse(existing.stdout) !== integrity) {
      throw new Error("Published WASM version does not match the verified artifact integrity");
    }
    // A retry must not move latest/next backwards after a newer release.
    return "already published (matching integrity; tags unchanged)";
  }
  let missing = false;
  for (const output of [existing.stdout, existing.stderr]) {
    try { missing ||= JSON.parse(output).error?.code === "E404"; } catch { /* Non-JSON npm diagnostics. */ }
  }
  if (!missing) throw new Error(`Cannot check published WASM version: ${existing.stderr || existing.stdout}`);
  const result = npm(["publish", tarball, "--access", "public", "--tag", tag]);
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`WASM publication failed: ${result.stderr || result.stdout}`);
  return "published";
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , version, artifactRoot, runFile, jobsFile, expectedCommit] = process.argv;
  const run = JSON.parse(readFileSync(runFile, "utf8"));
  const jobs = JSON.parse(readFileSync(jobsFile, "utf8")).flatMap(page => page.jobs);
  console.log(`zova-wasm@${version}: ${publishPackage({ version, artifactRoot, run, jobs, expectedCommit })}`);
}
