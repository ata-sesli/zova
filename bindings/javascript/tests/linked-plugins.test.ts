import { ptr } from "bun:ffi";
import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  abiVersion,
  abiVersionParts,
  AsyncDatabase,
  Database,
  LinkedPlugin,
  migrateDatabase,
  trustExtensionBundle,
  untrustExtensionBundle,
  verifyExtensionBundle,
  ZovaError,
} from "../js/index.js";

// `zova_plugin_descriptor_v1` from include/zova_plugin.h on a 64-bit target:
// u32 struct_size, u32 abi_version, u64 flags, five string pointers, four
// hook pointers. Module-level so the memory outlives every database.
const strings = ["linked_test", "1.0.0", "_zova_ext_linked_test_", "1.0.0"].map(
  (text) => new TextEncoder().encode(`${text}\0`),
);
const descriptor = new Uint8Array(88);
{
  const view = new DataView(descriptor.buffer);
  view.setUint32(0, descriptor.byteLength, true);
  view.setUint32(4, 1, true);
  strings.forEach((bytes, index) => view.setBigUint64(16 + 8 * index, BigInt(ptr(bytes)), true));
}

function linked(): LinkedPlugin {
  return LinkedPlugin.fromAddress(ptr(descriptor));
}

const temporaryDirectories: string[] = [];

function temporaryDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-linked-"));
  temporaryDirectories.push(directory);
  return directory;
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

function zovaCode(operation: () => unknown): string {
  try {
    operation();
  } catch (error) {
    expect(error).toBeInstanceOf(ZovaError);
    return (error as ZovaError).code;
  }
  throw new Error("expected a ZovaError");
}

describe("linked plugins and extension maintenance", () => {
  test("ABI version parts match the string", () => {
    const { major, minor, patch } = abiVersionParts;
    expect(`${major}.${minor}.${patch}`).toBe(abiVersion);
  });

  test("creates with a page size and validates plugin addresses", () => {
    const path = join(temporaryDirectory(), "pages.zova");
    const db = Database.createWithOptions(path, { pageSize: 8192 });
    const statement = db.prepare("pragma page_size");
    expect(statement.step()).toBe("row");
    expect(statement.columnInteger(0)).toBe(8192n);
    statement.close();
    db.close();
    expect(() => LinkedPlugin.fromAddress(0)).toThrow(ZovaError);
    expect(() => LinkedPlugin.fromAddress(-1n)).toThrow(ZovaError);
    expect(() => LinkedPlugin.fromAddress(0.5)).toThrow(ZovaError);
  });

  test("opens, upgrades, and rebuilds with a linked plugin", async () => {
    const path = join(temporaryDirectory(), "linked.zova");
    const created = Database.create(path, { plugins: [linked()] });
    created.installExtension("linked_test");
    created.close();

    expect(zovaCode(() => Database.open(path))).toBe("ZOVA_EXTENSION_UNAVAILABLE");
    const opened = Database.open(path, { extensions: { plugins: [linked()] } });
    expect(opened.extensionInfo("linked_test").version).toBe("1.0.0");
    opened.close();
    const asyncOpened = AsyncDatabase.open(path, { extensions: { plugins: [linked()] } });
    await asyncOpened.close();

    const maintenance = Database.openForExtensionUpgrade(path, {
      extensions: { plugins: [linked()] },
    });
    // The descriptor declares no newer version and no rebuild hook.
    expect(zovaCode(() => maintenance.extensionUpgrade("linked_test"))).toBe(
      "ZOVA_EXTENSION_INCOMPATIBLE",
    );
    expect(zovaCode(() => maintenance.extensionRebuild("linked_test"))).toBe(
      "ZOVA_EXTENSION_UNAVAILABLE",
    );
    maintenance.close();

    // The maintenance open skips hooks, so it succeeds without the code.
    const bare = Database.openForExtensionUpgrade(path);
    expect(zovaCode(() => bare.extensionUpgrade("linked_test"))).toBe("ZOVA_EXTENSION_UNAVAILABLE");
    bare.close();

    expect(
      zovaCode(() =>
        migrateDatabase(path, join(temporaryDirectory(), "no.zova"), true, { plugins: [linked()] }),
      ),
    ).toBe("ZOVA_NO_MIGRATION_PATH");
  });

  test("migrates with linked plugins, with and without progress", async () => {
    const directory = temporaryDirectory();
    const source = join(directory, "source.zova");
    copyFileSync(join(import.meta.dir, "..", "..", "..", "tests", "fixtures", "format-9.zova"), source);

    const destination = join(directory, "migrated.zova");
    migrateDatabase(source, destination, true, { plugins: [linked()] });
    Database.open(destination, { extensions: { plugins: [linked()] } }).close();

    let events = 0;
    await AsyncDatabase.migrateDatabase(source, join(directory, "progress.zova"), true, {
      plugins: [linked()],
    }, {
      progress: () => {
        events += 1;
      },
    });
    expect(events).toBeGreaterThan(0);
  });

  test("bundle trust functions report native errors", () => {
    const directory = temporaryDirectory();
    const trust = join(directory, "trust.json");
    const missing = join(directory, "missing.zovaext");
    expect(() => verifyExtensionBundle(missing, trust)).toThrow(ZovaError);
    expect(() => trustExtensionBundle(missing, trust)).toThrow(ZovaError);
    expect(untrustExtensionBundle("never_trusted", trust)).toBe(false);
  });
});
