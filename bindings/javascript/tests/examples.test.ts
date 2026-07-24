import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const packageDirectory = join(dirname(fileURLToPath(import.meta.url)), "..");
const temporaryDirectories: string[] = [];
const examples = ["sql", "objects", "vectors", "graphs"];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("examples", () => {
  for (const runtime of ["node", "bun"]) {
    test(`run under ${runtime}`, () => {
      for (const example of examples) {
        const directory = mkdtempSync(
          join(tmpdir(), `zova-javascript-example-${runtime}-`),
        );
        temporaryDirectories.push(directory);
        const result = spawnSync(
          runtime,
          [join(packageDirectory, "examples", "dist", `${example}.js`)],
          {
            cwd: directory,
            encoding: "utf8",
          },
        );
        expect(result.status, result.stderr || result.stdout).toBe(0);
      }
    });
  }
});
