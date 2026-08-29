import { describe, expect, test } from "bun:test";

import {
  abiVersion,
  formatVersion,
  packageVersion,
  sqliteVersion,
} from "../js/index.js";

describe("native binding metadata", () => {
  test("matches the current Zova release contract", () => {
    expect(packageVersion).toBe("1.0.0-rc.1");
    expect(abiVersion).toBe("1.0.0-rc.1");
    expect(formatVersion).toBe("11");
    expect(sqliteVersion).toBe("3.53.4");
  });
});
