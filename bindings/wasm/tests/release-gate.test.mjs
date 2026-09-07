import { test, expect } from "bun:test";
import { verifyArtifactRun } from "../tools/verify-artifact-run.mjs";
import { publishPackage } from "../tools/publish-package.mjs";
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
const run = { head_sha: "abc", status: "completed", conclusion: "success", path: ".github/workflows/release-artifacts.yml" };
const jobs = [{ name: "wasm / WASM browser package", conclusion: "success" }];
test("release workflow publishes WASM without a prerelease-only condition", () => {
  const workflow = readFileSync(new URL("../../../.github/workflows/publish-release.yml", import.meta.url), "utf8");
  const step = workflow.split("      - name: Publish WASM package\n")[1]?.split("      - name:")[0];
  expect(step).toBeDefined();
  expect(step).not.toMatch(/^\s*if:/m);
  expect(step).toContain("node bindings/wasm/tools/publish-package.mjs");
  expect(step).toContain('$RUNNER_TEMP/artifact-run.json');
  expect(step).toContain('$RUNNER_TEMP/artifact-jobs.json');
  expect(step).toContain('$(git rev-parse HEAD)');
});
for (const [version, tag] of [["1.0.0", "latest"], ["1.0.0-rc.3", "next"]]) {
  test(`publication policy and retry safety for ${version}`, () => {
    const artifactRoot = mkdtempSync(join(tmpdir(), "zova-wasm-publish-"));
    const tarball = join(artifactRoot, `zova-${version}-wasm`, `zova-wasm-${version}.tgz`);
    const bytes = Buffer.from("test artifact, never published");
    const integrity = `sha512-${createHash("sha512").update(bytes).digest("base64")}`;
    const options = { version, artifactRoot, run, jobs, expectedCommit: "abc" };
    let calls = [];
    let response = { status: 1, stdout: JSON.stringify({ error: { code: "E404" } }) };
    const npm = args => {
      calls.push(args);
      return args[0] === "view" ? response : { status: 0 };
    };
    try {
      expect(() => publishPackage(options, npm)).toThrow();
      expect(calls).toEqual([]);
      mkdirSync(dirname(tarball), { recursive: true });
      writeFileSync(tarball, bytes);
      for (const change of [{ run: { ...run, head_sha: "old" } }, { run: { ...run, conclusion: "failure" } }, { jobs: [] }]) {
        expect(() => publishPackage({ ...options, ...change }, npm)).toThrow();
      }
      expect(calls).toEqual([]);
      expect(publishPackage(options, npm)).toBe("published");
      expect(calls).toEqual([
        ["view", `zova-wasm@${version}`, "dist.integrity", "--json"],
        ["publish", tarball, "--access", "public", "--tag", tag],
      ]);
      calls = [];
      response = { status: 0, stdout: JSON.stringify(integrity) };
      expect(publishPackage(options, npm)).toBe("already published (matching integrity; tags unchanged)");
      expect(calls.length).toBe(1);
      for (const bad of [
        { status: 0, stdout: JSON.stringify("sha512-wrong") },
        { status: 0, stdout: "null" },
        { status: 1, stdout: JSON.stringify({ error: { code: "E403" } }) },
        { status: 1, stderr: "network unavailable" },
      ]) {
        calls = [];
        response = bad;
        expect(() => publishPackage(options, npm)).toThrow();
        expect(calls.length).toBe(1);
      }
      response = { status: 1, stdout: JSON.stringify({ error: { code: "E404" } }) };
      expect(() => publishPackage(options, args => args[0] === "view" ? response : { status: 1, stderr: "publish rejected" })).toThrow("publish rejected");
      expect(() => publishPackage({ ...options, version: "../bad" }, npm)).toThrow();
    } finally { rmSync(artifactRoot, { recursive: true, force: true }); }
  });
}
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
