import { test, expect } from "bun:test";
import { verifyArtifactRun } from "../tools/verify-artifact-run.mjs";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
const run = { head_sha: "abc", status: "completed", conclusion: "success", path: ".github/workflows/release-artifacts.yml" };
const jobs = [{ name: "wasm / WASM browser package", conclusion: "success" }];
test("requires a successful matching artifact workflow and browser job", () => {
  expect(() => verifyArtifactRun(run, jobs, "abc")).not.toThrow();
  for (const change of [{ head_sha: "old" }, { status: "in_progress" }, { conclusion: "failure" }, { path: ".github/workflows/ci.yml" }]) {
    expect(() => verifyArtifactRun({ ...run, ...change }, jobs, "abc")).toThrow();
  }
  expect(() => verifyArtifactRun(run, [], "abc")).toThrow();
  expect(() => verifyArtifactRun(run, [{ ...jobs[0], conclusion: "skipped" }], "abc")).toThrow();
});
test("central version bump updates WASM without changing storage format", () => {
  const root = fileURLToPath(new URL("../../../", import.meta.url));
  const fixture = mkdtempSync(join(tmpdir(), "zova-wasm-version-"));
  try {
    for (const relative of ["scripts/bump-version.sh", "src/version.zig", "bindings/wasm/package.json", "bindings/wasm/bun.lock", "bindings/wasm/README.md"]) {
      mkdirSync(dirname(join(fixture, relative)), { recursive: true });
      cpSync(join(root, relative), join(fixture, relative));
    }
    const run = Bun.spawnSync(["sh", join(fixture, "scripts/bump-version.sh"), "9.8.7-rc.1"]);
    expect(run.exitCode).toBe(0);
    expect(JSON.parse(readFileSync(join(fixture, "bindings/wasm/package.json"), "utf8")).version).toBe("9.8.7-rc.1");
    expect(readFileSync(join(fixture, "bindings/wasm/README.md"), "utf8")).toContain("9.8.7-rc.1");
    expect(readFileSync(join(fixture, "src/version.zig"), "utf8")).toContain('format_version = "11"');
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});
