// Fails when the public API changes without review:
// - the emitted dist/index.d.ts differs from the reviewed api/index.d.ts;
// - a public name of native zova-js is missing from the first column of the
//   README's "Native API parity" table.
//
//   bun tools/check-api.mjs           check both
//   bun tools/check-api.mjs --update  accept the emitted declarations
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import ts from "typescript";

const root = new URL("..", import.meta.url).pathname;
const nativeSources = new URL("../../javascript/js/", import.meta.url).pathname;
const snapshot = join(root, "api/index.d.ts");
const problems = [];

// Declarations, emitted exactly as tools/build-package.sh does.
const out = mkdtempSync(join(tmpdir(), "zova-wasm-api-"));
try {
  execFileSync(process.execPath, [join(root, "node_modules/typescript/bin/tsc"), "--project", join(root, "tsconfig.json"),
    "--outDir", out, "--emitDeclarationOnly"], { stdio: "inherit" });
  const emitted = readFileSync(join(out, "index.d.ts"), "utf8");
  if (process.argv.includes("--update")) {
    writeFileSync(snapshot, emitted);
    console.log(`updated ${snapshot}`);
  } else if (emitted !== readFileSync(snapshot, "utf8")) {
    problems.push("dist/index.d.ts differs from api/index.d.ts. Review the change, then run: bun tools/check-api.mjs --update");
  }
} finally { rmSync(out, { recursive: true, force: true }); }

// Public value names of zova-js: exported classes with their public members,
// functions and constants. Type-only exports have no browser call to map.
const exported = new Set();
const files = readdirSync(nativeSources).filter(name => name.endsWith(".ts"))
  .map(name => ts.createSourceFile(name, readFileSync(join(nativeSources, name), "utf8"), ts.ScriptTarget.ES2022, true));
for (const statement of files.find(file => file.fileName === "index.ts").statements) {
  if (ts.isExportDeclaration(statement) && !statement.isTypeOnly && statement.exportClause && ts.isNamedExports(statement.exportClause)) {
    for (const element of statement.exportClause.elements) exported.add(element.name.text);
  } else if (ts.isVariableStatement(statement) && statement.modifiers?.some(m => m.kind === ts.SyntaxKind.ExportKeyword)) {
    for (const declaration of statement.declarationList.declarations) exported.add(declaration.name.getText());
  }
}
const hidden = member => !member.name || ts.isPrivateIdentifier(member.name) || ts.isConstructorDeclaration(member)
  || member.modifiers?.some(m => m.kind === ts.SyntaxKind.PrivateKeyword || m.kind === ts.SyntaxKind.ProtectedKeyword);
const names = new Set(exported);
for (const file of files) {
  for (const statement of file.statements) {
    if (!ts.isClassDeclaration(statement) || !exported.has(statement.name?.text)) continue;
    for (const member of statement.members) if (!hidden(member)) names.add(member.name.getText());
  }
}

// Names in backticks in the table's native column, split at "(" and ".".
const readme = readFileSync(join(root, "README.md"), "utf8");
const section = readme.split(/^## /m).find(part => part.startsWith("Native API parity"));
if (!section) problems.push('README.md has no "Native API parity" section');
const listed = new Set();
for (const line of (section ?? "").split("\n")) {
  const cell = line.match(/^\| (.*?) \|/)?.[1];
  if (!cell) continue;
  for (const [, code] of cell.matchAll(/`([^`]+)`/g)) for (const word of code.match(/[A-Za-z_]\w*/g) ?? []) listed.add(word);
}
for (const name of [...names].sort()) {
  if (!listed.has(name)) problems.push(`zova-js ${name} has no row in the README "Native API parity" table`);
}

for (const problem of problems) console.error(problem);
console.log(`${names.size} zova-js names checked against the parity table`);
process.exit(problems.length ? 1 : 0);
