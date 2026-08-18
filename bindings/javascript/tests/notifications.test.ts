import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  AsyncDatabase,
  Database,
  type KvEntry,
  type Notification,
  Subscription,
} from "../js/index.js";

const temporaryDirectories: string[] = [];

function temporaryDatabasePath(): string {
  const directory = mkdtempSync(join(tmpdir(), "zova-javascript-notify-"));
  temporaryDirectories.push(directory);
  return join(directory, "test.zova");
}

function bytes(value: string | number[]): Uint8Array {
  if (typeof value === "string") {
    return new TextEncoder().encode(value);
  }
  return new Uint8Array(value);
}

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("Database notifications", () => {
  test("delivers immediately outside transactions and after commit", () => {
    const database = Database.create(temporaryDatabasePath());
    const subscription = database.listen("messages");
    try {
      database.notify("messages", "outside");
      const note = subscription.tryReceive();
      expect(note).not.toBeNull();
      expect(note!.channel).toBe("messages");
      expect(note!.payload).toBe("outside");
      expect(note!.sequence).toBe(1n);
      expect(note!.droppedBefore).toBe(0n);
      expect(subscription.tryReceive()).toBeNull();

      database.beginImmediate();
      database.notify("messages", "committed");
      expect(subscription.tryReceive()).toBeNull();
      database.commit();
      expect(subscription.tryReceive()!.payload).toBe("committed");
    } finally {
      subscription.close();
      database.close();
    }
  });

  test("discards notifications on rollback and savepoint rollback", () => {
    const database = Database.create(temporaryDatabasePath());
    const subscription = database.listen("messages");
    try {
      database.beginImmediate();
      database.notify("messages", "rolled-back");
      database.rollback();
      expect(subscription.tryReceive()).toBeNull();

      database.beginImmediate();
      database.notify("messages", "outer");
      database.savepoint("inner");
      database.notify("messages", "discarded");
      database.rollbackToSavepoint("inner");
      database.notify("messages", "after-rollback-to");
      database.releaseSavepoint("inner");
      database.commit();

      expect(subscription.tryReceive()!.payload).toBe("outer");
      expect(subscription.tryReceive()!.payload).toBe("after-rollback-to");
      expect(subscription.tryReceive()).toBeNull();
    } finally {
      subscription.close();
      database.close();
    }
  });

  test("supports multiple listeners on one handle", () => {
    const database = Database.create(temporaryDatabasePath());
    const first = database.listen("events");
    const second = database.listen("events");
    const other = database.listen("other");
    try {
      database.notify("events", "one");
      expect(first.tryReceive()!.payload).toBe("one");
      expect(second.tryReceive()!.payload).toBe("one");
      expect(other.tryReceive()).toBeNull();
    } finally {
      first.close();
      second.close();
      other.close();
      database.close();
    }
  });

  test("rejects invalid channels and validates SQL notify", () => {
    const database = Database.create(temporaryDatabasePath());
    const subscription = database.listen("messages");
    try {
      expect(() => database.listen("_zova_private")).toThrow();
      expect(() => database.notify("bad channel", "payload")).toThrow();

      database.exec("select zova_notify('messages', 'from-sql')");
      expect(subscription.tryReceive()!.payload).toBe("from-sql");
    } finally {
      subscription.close();
      database.close();
    }
  });

  test("reports queue overflow dropped counts", () => {
    const database = Database.createMemory();
    const subscription = database.listen("overflow");
    try {
      for (let index = 0; index < 1025; index += 1) {
        database.notify("overflow", `event-${index}`);
      }
      const note = subscription.tryReceive()!;
      expect(note.payload).toBe("event-1");
      expect(note.droppedBefore).toBe(1n);
    } finally {
      subscription.close();
      database.close();
    }
  });

  test("emits one aggregate notification after an atomic kv batch", () => {
    const database = Database.createMemory();
    const subscription = database.listen("cache:search-results");
    try {
      database.beginImmediate();
      const entries: KvEntry[] = [
        { key: bytes("result-1"), value: bytes("one") },
        { key: bytes("result-2"), value: bytes("two") },
      ];
      database.kvPutMany(bytes("search-results"), entries);
      database.notify("cache:search-results", "generation:42");
      database.commit();

      expect(subscription.tryReceive()!.payload).toBe("generation:42");
      expect(
        database.kvGet(bytes("search-results"), bytes("result-1")),
      ).toEqual(bytes("one"));
    } finally {
      subscription.close();
      database.close();
    }
  });

  test("closes subscription before database close", () => {
    const database = Database.create(temporaryDatabasePath());
    const subscription = database.listen("messages");
    subscription.close();
    expect(subscription.closed).toBe(true);
    expect(() => subscription.tryReceive()).toThrow();
    database.close();
    expect(database.closed).toBe(true);
  });
});

describe("AsyncDatabase notifications", () => {
  test("async listen notify and receive deliver committed events", async () => {
    const database = AsyncDatabase.create(temporaryDatabasePath());
    try {
      const subscription = await database.listen("messages");

      await database.notify("messages", "outside");
      const note = await subscription.tryReceiveAsync();
      expect(note).not.toBeNull();
      expect(note!.channel).toBe("messages");
      expect(note!.payload).toBe("outside");
      expect(note!.sequence).toBe(1n);

      await database.notify("messages", "second");
      expect((await subscription.tryReceiveAsync())!.payload).toBe("second");
      expect(await subscription.tryReceiveAsync()).toBeNull();

      subscription.close();
    } finally {
      await database.close();
    }
  });
});
