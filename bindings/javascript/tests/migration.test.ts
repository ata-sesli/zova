import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  AsyncDatabase,
  Database,
  migrateDatabase,
  probeFormat,
  Step,
  ZovaError,
} from "../js/index.js";

const temporaryDirectories: string[] = [];

function temporaryDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-migration-"));
  temporaryDirectories.push(directory);
  return directory;
}

function format9FixtureCopy(name: string): string {
  const directory = temporaryDirectory();
  const source = join(directory, name);
  copyFileSync(
    join(import.meta.dir, "..", "..", "..", "tests", "fixtures", "format-9.zova"),
    source,
  );
  return source;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.byteLength === b.byteLength && a.every((byte, index) => byte === b[index]);
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("Storage-format migration", () => {
  test("probeFormat classifies migratable and current formats", () => {
    const source = format9FixtureCopy("probe-source.zova");
    const before = readFileSync(source);

    const info = probeFormat(source);
    expect(info.formatVersion).toBe(9);
    expect(info.compatibility).toBe("migratable");

    const current = join(temporaryDirectory(), "current.zova");
    const database = Database.create(current);
    database.exec("create table t(id integer)");
    database.close();

    const currentInfo = probeFormat(current);
    expect(currentInfo.formatVersion).toBe(10);
    expect(currentInfo.compatibility).toBe("current");

    expect(sameBytes(readFileSync(source), before)).toBe(true);
  });

  test("probeFormat rejects non-Zova paths", () => {
    const path = join(temporaryDirectory(), "not-zova.txt");
    writeFileSync(path, "not a zova file");
    expect(() => probeFormat(path)).toThrow(ZovaError);
    try {
      probeFormat(path);
    } catch (error) {
      expect((error as ZovaError).code).toBe("ZOVA_NOT_ZOVA_PATH");
    }
  });

  test("migrateDatabase copies the fixture forward and reopens", () => {
    const source = format9FixtureCopy("migrate-source.zova");
    const destination = join(temporaryDirectory(), "migrate-destination.zova");
    const before = readFileSync(source);

    migrateDatabase(source, destination);

    const info = probeFormat(destination);
    expect(info.formatVersion).toBe(10);
    expect(info.compatibility).toBe("current");
    expect(sameBytes(readFileSync(source), before)).toBe(true);

    const database = Database.open(destination);
    const statement = database.prepare("select count(*) from user_documents");
    expect(statement.step()).toBe(Step.Row);
    expect(statement.columnInteger(0)).toBe(3n);
    expect(statement.step()).toBe(Step.Done);
    statement.close();
    database.exec("create table post_migration(id integer primary key, note text)");
    database.close();
  });

  test("migrateDatabase refuses existing destinations", () => {
    const source = format9FixtureCopy("migrate-fail-source.zova");
    const destination = join(temporaryDirectory(), "occupied.zova");
    writeFileSync(destination, "occupied");
    try {
      migrateDatabase(source, destination);
      throw new Error("expected migrateDatabase to fail");
    } catch (error) {
      expect(error).toBeInstanceOf(ZovaError);
      expect((error as ZovaError).code).toBe("ZOVA_DESTINATION_EXISTS");
    }
  });

  test("migrateDatabase reports no migration path for current formats", () => {
    const directory = temporaryDirectory();
    const current = join(directory, "current-source.zova");
    const destination = join(directory, "current-destination.zova");
    const database = Database.create(current);
    database.exec("create table t(id integer)");
    database.close();

    try {
      migrateDatabase(current, destination);
      throw new Error("expected migrateDatabase to fail");
    } catch (error) {
      expect(error).toBeInstanceOf(ZovaError);
      expect((error as ZovaError).code).toBe("ZOVA_NO_MIGRATION_PATH");
    }
    expect(() => readFileSync(destination)).toThrow();
  });

  test("async probe and migration run off the event loop and match sync results", async () => {
    const source = format9FixtureCopy("async-migrate-source.zova");
    const destination = join(temporaryDirectory(), "async-migrate-destination.zova");

    const info = await AsyncDatabase.probeFormat(source);
    expect(info.formatVersion).toBe(9);
    expect(info.compatibility).toBe("migratable");

    await AsyncDatabase.migrateDatabase(source, destination);

    const migratedInfo = await AsyncDatabase.probeFormat(destination);
    expect(migratedInfo.formatVersion).toBe(10);
    expect(migratedInfo.compatibility).toBe("current");

    const syncInfo = probeFormat(destination);
    expect(syncInfo.formatVersion).toBe(migratedInfo.formatVersion);
    expect(syncInfo.compatibility).toBe(migratedInfo.compatibility);
  });
});
