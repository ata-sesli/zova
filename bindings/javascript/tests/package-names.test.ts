import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { normalizePackageNames } from "../tools/normalize-package-names";

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("native npm package names", () => {
  test("maps generated package names to stable native companions idempotently", () => {
    const root = mkdtempSync(join(tmpdir(), "zova-js-package-names-"));
    temporaryDirectories.push(root);

    const targets = [
      {
        directory: "darwin-arm64",
        generated: "zova-js-darwin-arm64",
        published: "zova-db-darwin-arm64",
      },
      {
        directory: "darwin-x64",
        generated: "zova-js-darwin-x64",
        published: "zova-db-darwin-x64",
      },
      {
        directory: "linux-arm64-gnu",
        generated: "zova-js-linux-arm64-gnu",
        published: "zova-db-linux-arm64-gnu",
      },
      {
        directory: "linux-x64-gnu",
        generated: "zova-js-linux-x64-gnu",
        published: "zova-db-linux-x64-gnu",
      },
      {
        directory: "win32-x64-msvc",
        generated: "zova-js-win32-x64-msvc",
        published: "zova-db-windows-x64",
      },
    ];

    writeFileSync(
      join(root, "package.json"),
      `${JSON.stringify(
        {
          name: "zova-js",
          version: "1.0.0-rc.2",
          optionalDependencies: Object.fromEntries(
            targets.map(({ generated }) => [generated, "1.0.0-rc.2"]),
          ),
        },
        null,
        2,
      )}\n`,
    );
    writeFileSync(
      join(root, "index.js"),
      `${targets
        .flatMap(({ generated }) => [
          `require('${generated}')`,
          `require('${generated}/package.json')`,
        ])
        .join("\n")}\n`,
    );
    for (const { directory, generated } of targets) {
      const targetDirectory = join(root, "npm", directory);
      mkdirSync(targetDirectory, { recursive: true });
      writeFileSync(
        join(targetDirectory, "package.json"),
        `${JSON.stringify(
          {
            name: generated,
            version: "1.0.0-rc.2",
            marker: directory,
          },
          null,
          2,
        )}\n`,
      );
      writeFileSync(
        join(targetDirectory, "README.md"),
        `# \`${generated}\`\n`,
      );
    }

    normalizePackageNames(root);
    normalizePackageNames(root);

    const rootPackage = JSON.parse(
      readFileSync(join(root, "package.json"), "utf8"),
    );
    expect(rootPackage.optionalDependencies).toEqual(
      Object.fromEntries(
        targets.map(({ published }) => [published, "1.0.0-rc.2"]),
      ),
    );

    const loader = readFileSync(join(root, "index.js"), "utf8");
    for (const { directory, generated, published } of targets) {
      expect(loader).toContain(`require('${published}')`);
      expect(loader).toContain(`require('${published}/package.json')`);
      expect(loader).not.toContain(generated);

      const targetDirectory = join(root, "npm", directory);
      const packageJson = JSON.parse(
        readFileSync(join(targetDirectory, "package.json"), "utf8"),
      );
      expect(packageJson.name).toBe(published);
      expect(packageJson.marker).toBe(directory);
      expect(readFileSync(join(targetDirectory, "README.md"), "utf8")).toBe(
        `# \`${published}\`\n`,
      );
    }
  });
});
