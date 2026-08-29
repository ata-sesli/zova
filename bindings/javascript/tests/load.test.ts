import { describe, expect, test } from "bun:test";

import {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} from "../js/index.js";

describe("native binding metadata", () => {
  test("matches the current Zova release contract", () => {
    expect(packageVersion).toBe("0.26.1");
    expect(abiVersion).toBe("0.26.1");
    expect(formatVersion).toBe("11");
    expect(sqliteVersion).toBe("3.53.4");
  });
});
