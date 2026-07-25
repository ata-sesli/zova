import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const PACKAGE_NAMES = [
  {
    directory: "darwin-arm64",
    generated: "zova-js-darwin-arm64",
    published: "zova-db-darwin-arm64",
    aliases: [],
  },
  {
    directory: "darwin-x64",
    generated: "zova-js-darwin-x64",
    published: "zova-db-darwin-x64",
    aliases: [],
  },
  {
    directory: "linux-arm64-gnu",
    generated: "zova-js-linux-arm64-gnu",
    published: "zova-db-linux-arm64-gnu",
    aliases: [],
  },
  {
    directory: "linux-x64-gnu",
    generated: "zova-js-linux-x64-gnu",
    published: "zova-db-linux-x64-gnu",
    aliases: [],
  },
  {
    directory: "win32-x64-msvc",
    generated: "zova-js-win32-x64-msvc",
    published: "zova-db-windows-x64",
    aliases: ["zova-js-windows-x64"],
  },
] as const;

type PackageJson = {
  name?: string;
  version?: string;
  optionalDependencies?: Record<string, string>;
};

function readJson(path: string): PackageJson {
  return JSON.parse(readFileSync(path, "utf8"));
}

function writeJson(path: string, value: PackageJson): void {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

function normalizeRootPackage(root: string): void {
  const path = join(root, "package.json");
  const packageJson = readJson(path);
  if (packageJson.name !== "zova-js") {
    throw new Error(`expected zova-js root package, found ${packageJson.name}`);
  }

  const dependencies = packageJson.optionalDependencies;
  if (dependencies === undefined) {
    throw new Error("root package has no optionalDependencies");
  }

  for (const { aliases, generated, published } of PACKAGE_NAMES) {
    const sourceNames = [generated, published, ...aliases];
    const version = sourceNames
      .map((name) => dependencies[name])
      .find((dependencyVersion) => dependencyVersion !== undefined);
    if (version === undefined) {
      throw new Error(`root package has no native dependency for ${generated}`);
    }

    for (const name of sourceNames) {
      if (name !== published) {
        delete dependencies[name];
      }
    }
    dependencies[published] = version;
  }

  writeJson(path, packageJson);
}

function normalizeLoader(root: string): void {
  const path = join(root, "index.js");
  if (!existsSync(path)) {
    return;
  }

  let loader = readFileSync(path, "utf8");
  for (const { aliases, generated, published } of PACKAGE_NAMES) {
    const sourceNames = [generated, published, ...aliases];
    if (!sourceNames.some((name) => loader.includes(name))) {
      throw new Error(`generated loader has no reference for ${generated}`);
    }
    for (const name of sourceNames) {
      loader = loader.replaceAll(name, published);
    }
  }

  writeFileSync(path, loader);
}

function normalizeNativePackage(
  root: string,
  directoryName: string,
  generated: string,
  published: string,
  aliases: readonly string[],
): void {
  const directory = join(root, "npm", directoryName);
  const packagePath = join(directory, "package.json");
  if (!existsSync(packagePath)) {
    return;
  }

  const packageJson = readJson(packagePath);
  const sourceNames = [generated, published, ...aliases];
  if (!sourceNames.includes(packageJson.name ?? "")) {
    throw new Error(`unexpected native package name: ${packageJson.name}`);
  }

  packageJson.name = published;
  writeJson(packagePath, packageJson);

  const readmePath = join(directory, "README.md");
  if (existsSync(readmePath)) {
    const readme = readFileSync(readmePath, "utf8");
    writeFileSync(
      readmePath,
      sourceNames.reduce(
        (normalized, name) => normalized.replaceAll(name, published),
        readme,
      ),
    );
  }
}

export function normalizePackageNames(root = process.cwd()): void {
  normalizeRootPackage(root);
  normalizeLoader(root);
  for (const { aliases, directory, generated, published } of PACKAGE_NAMES) {
    normalizeNativePackage(root, directory, generated, published, aliases);
  }
}

if (import.meta.main) {
  normalizePackageNames();
}
