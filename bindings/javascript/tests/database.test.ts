import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  Database,
  restoreBackup,
  Step,
  ZovaError,
} from "../js/index.js";

const temporaryDirectories: string[] = [];

function temporaryDatabasePath(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-"));
  temporaryDirectories.push(directory);
  return join(directory, "test.zova");
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("Database and Statement", () => {
  test("round-trips every SQLite value type with bigint integers", () => {
    const database = Database.create(temporaryDatabasePath());
    database.exec(`
      CREATE TABLE values_table (
        integer_value INTEGER,
        float_value REAL,
        text_value TEXT,
        blob_value BLOB,
        null_value TEXT
      )
    `);

    const insert = database.prepare(
      "INSERT INTO values_table VALUES (?1, ?2, ?3, ?4, ?5)",
    );
    expect(insert.parameterCount()).toBe(5);
    expect(insert.parameterIndex("?3")).toBe(3);
    insert.bindInteger(1, 9_007_199_254_740_993n);
    insert.bindFloat(2, 3.5);
    insert.bindText(3, "sage");
    insert.bindBlob(4, new Uint8Array([0, 1, 255]));
    insert.bindNull(5);
    expect(insert.step()).toBe(Step.Done);
    insert.close();

    const select = database.prepare("SELECT * FROM values_table");
    expect(select.step()).toBe(Step.Row);
    expect(select.columnCount()).toBe(5);
    expect(select.columnName(0)).toBe("integer_value");
    expect(select.columnType(0)).toBe("integer");
    expect(select.columnInteger(0)).toBe(9_007_199_254_740_993n);
    expect(select.columnFloat(1)).toBe(3.5);
    expect(select.columnText(2)).toBe("sage");
    expect(select.columnBlob(3)).toEqual(new Uint8Array([0, 1, 255]));
    expect(select.columnText(4)).toBeNull();
    expect(select.step()).toBe(Step.Done);
    select.close();
    database.close();
  });

  test("reset retains bindings and clearBindings removes them", () => {
    const database = Database.create(temporaryDatabasePath());
    const statement = database.prepare("SELECT ?1");

    statement.bindText(1, "retained");
    expect(statement.step()).toBe(Step.Row);
    expect(statement.columnText(0)).toBe("retained");
    statement.reset();
    expect(statement.step()).toBe(Step.Row);
    expect(statement.columnText(0)).toBe("retained");
    statement.reset();
    statement.clearBindings();
    expect(statement.step()).toBe(Step.Row);
    expect(statement.columnText(0)).toBeNull();

    statement.close();
    database.close();
  });

  test("close is idempotent and closed handles reject later calls", () => {
    const database = Database.create(temporaryDatabasePath());
    database.close();
    database.close();

    expect(() => database.exec("SELECT 1")).toThrow(ZovaError);
    try {
      database.exec("SELECT 1");
    } catch (error) {
      expect(error).toBeInstanceOf(ZovaError);
      expect((error as ZovaError).code).toBe("ZOVA_MISUSE");
    }
  });

  test("database close rejects live statements without invalidating them", () => {
    const database = Database.create(temporaryDatabasePath());
    const statement = database.prepare("SELECT 1");

    expect(() => database.close()).toThrow(ZovaError);
    expect(statement.step()).toBe(Step.Row);
    expect(statement.columnInteger(0)).toBe(1n);

    statement.close();
    database.close();
  });

  test("transaction commits values and rolls back thrown exceptions", () => {
    const database = Database.create(temporaryDatabasePath());
    database.exec("CREATE TABLE notes(body TEXT)");

    const result = database.transaction((transaction) => {
      transaction.exec("INSERT INTO notes VALUES ('kept')");
      return 42;
    });
    expect(result).toBe(42);

    expect(() =>
      database.transaction((transaction) => {
        transaction.exec("INSERT INTO notes VALUES ('rolled back')");
        throw new Error("stop");
      }),
    ).toThrow("stop");

    const count = database.prepare("SELECT count(*) FROM notes");
    expect(count.step()).toBe(Step.Row);
    expect(count.columnInteger(0)).toBe(1n);
    count.close();
    database.close();
  });

  test("transaction rejects Promise results before commit", () => {
    const database = Database.create(temporaryDatabasePath());
    database.exec("CREATE TABLE notes(body TEXT)");

    expect(() =>
      database.transaction((transaction) => {
        transaction.exec("INSERT INTO notes VALUES ('rolled back')");
        return Promise.resolve("not allowed");
      }),
    ).toThrow(ZovaError);

    const count = database.prepare("SELECT count(*) FROM notes");
    expect(count.step()).toBe(Step.Row);
    expect(count.columnInteger(0)).toBe(0n);
    count.close();
    database.close();
  });

  test("savepoint callback releases on success and rolls back on error", () => {
    const database = Database.create(temporaryDatabasePath());
    database.exec("CREATE TABLE notes(body TEXT)");

    database.savepoint("kept", (savepoint) => {
      savepoint.exec("INSERT INTO notes VALUES ('kept')");
    });
    expect(() =>
      database.savepoint("discarded", (savepoint) => {
        savepoint.exec("INSERT INTO notes VALUES ('discarded')");
        throw new Error("discard");
      }),
    ).toThrow("discard");

    const values = database.prepare("SELECT body FROM notes ORDER BY rowid");
    expect(values.step()).toBe(Step.Row);
    expect(values.columnText(0)).toBe("kept");
    expect(values.step()).toBe(Step.Done);
    values.close();
    database.close();
  });

  test("read-only open preserves reads and rejects writes", () => {
    const path = temporaryDatabasePath();
    const writable = Database.create(path);
    writable.exec("CREATE TABLE notes(body TEXT)");
    writable.exec("INSERT INTO notes VALUES ('hello')");
    writable.close();

    const readOnly = Database.open(path, { readOnly: true });
    const statement = readOnly.prepare("SELECT body FROM notes");
    expect(statement.step()).toBe(Step.Row);
    expect(statement.columnText(0)).toBe("hello");
    statement.close();
    expect(() =>
      readOnly.exec("INSERT INTO notes VALUES ('blocked')"),
    ).toThrow(ZovaError);
    readOnly.close();
  });

  test("backup, compact, and restore preserve database contents", () => {
    const source = temporaryDatabasePath();
    const directory = temporaryDirectories.at(-1);
    if (directory === undefined) {
      throw new Error("temporary directory was not created");
    }
    const backup = join(directory, "backup.zova");
    const compact = join(directory, "compact.zova");
    const restored = join(directory, "restored.zova");

    const database = Database.create(source);
    database.exec("CREATE TABLE notes(body TEXT)");
    database.exec("INSERT INTO notes VALUES ('hello')");
    database.backupTo(backup);
    database.compactTo(compact);
    database.close();

    restoreBackup(backup, restored);
    for (const path of [backup, compact, restored]) {
      const copy = Database.open(path);
      const statement = copy.prepare("SELECT body FROM notes");
      expect(statement.step()).toBe(Step.Row);
      expect(statement.columnText(0)).toBe("hello");
      statement.close();
      copy.close();
    }
  });

  test("embedded NUL text is reported as an invalid argument", () => {
    const database = Database.create(temporaryDatabasePath());
    expect(() => database.exec("SELECT '\0'")).toThrow(ZovaError);
    try {
      database.exec("SELECT '\0'");
    } catch (error) {
      expect((error as ZovaError).code).toBe("ZOVA_INVALID_ARGUMENT");
      expect((error as ZovaError).status).toBe(1);
    }
    database.close();
  });
});
