// Preserve the original standalone spike command.
process.argv.push("--spike");
await import("./build-opfs.mjs");
