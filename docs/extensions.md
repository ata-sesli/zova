# Zova Extensions

Zova extensions are trusted process code that can install and manage private
Zova storage, then expose a SQL surface on every opened connection.

The database stores extension metadata. It does not store executable code,
library paths, search paths, or anything that Zova auto-loads.

## Model

An extension has two parts:

- a manifest that names the extension and its private storage prefix
- process-provided code with lifecycle and SQL-registration hooks

Installed metadata lives in `_zova_extensions`. Extension-owned private storage
must use `_zova_ext_<name>_...` names. For example, an extension named `trgm`
owns `_zova_ext_trgm_docs`, `_zova_ext_trgm_postings`, and indexes with the
same prefix.

In v0.21 development builds, all installed extensions are required. Opening a
database with installed extension metadata but without matching process code
fails during normal open. Diagnostic commands can still inspect the metadata so
they can explain what is missing.

## Trust Boundary

Extension code is native trusted code. Treat it like application code linked
into the same process.

A `.zova` file may say which extensions it needs, but the application or CLI
process decides which extension code is available. Zova never loads code just
because a database asks for it.

Deferred for later v0.21 work:

- dynamic trusted local extension artifacts
- extension trust stores
- extension signing
- marketplace or network fetching
- optional installed extensions
- C ABI, Rust, Go, or Python lifecycle APIs

## Manifest

The foundation manifest contains:

- `name`: ASCII, 1-64 bytes, outside the reserved `_zova_` namespace
- `version`: extension version text
- `storage_prefix`: exactly `_zova_ext_<name>_`
- `zova_abi_min`: minimum Zova ABI version expected by the extension
- `capabilities`: short capability text
- `required`: must be `true` in the current host slice
- `manifest_json`: optional extra manifest data, bounded and stored as text

Names, prefixes, duplicate registry prefixes, duplicate installed prefixes, and
invalid installed rows are rejected.

## Lifecycle

Install and drop run inside a lifecycle savepoint.

On install:

1. Zova validates the manifest and registry.
2. The install hook creates extension-owned storage.
3. Zova records the installed metadata row.
4. The optional SQL registration hook runs.
5. Zova audits extension private storage ownership.
6. Zova validates core private schema.
7. The lifecycle savepoint is released.

If any step fails, Zova rolls back the savepoint. The database must not be left
with a partial install.

On drop:

1. Zova validates installed metadata and matching process code.
2. The drop hook removes extension-owned storage.
3. Zova removes the installed metadata row.
4. Zova audits that no owned private objects remain.
5. Zova validates core private schema.
6. The lifecycle savepoint is released.

If an extension leaves `_zova_ext_<name>_...` storage behind, drop fails and the
metadata row remains installed.

Update, enable, and disable are deferred.

## SQL Registration

An extension may register connection-local SQL functions or read-only virtual
tables from its `register_sql` hook.

SQL registration runs when a Zova connection opens with matching registered
extension code. It also runs after install before the lifecycle savepoint is
released, so extension checks can use the SQL surface immediately.

Do not put executable code paths in database metadata. Do not load extension
code from SQL.

## Storage Rules

Extensions may create private SQLite tables, indexes, views, and triggers only
under their own prefix:

```text
_zova_ext_<name>_...
```

They must not claim or damage core Zova storage such as `_zova_objects`,
`_zova_vectors`, `_zova_graphs`, `_zova_extensions`, or `_zova_meta`.

Unknown `_zova_ext_*` objects without an installed owner are reported by
diagnostics as extension issues.

Extension private storage lives in the main database in this host slice.

## Diagnostics

`zova check --deep` and `zova doctor` report extension issues without printing
private schema SQL or indexed/private data.

They can inspect installed metadata even when normal open fails because required
extension code is unavailable.

`zova extension list` and `zova extension info` can also inspect installed
metadata without registered code. `zova extension check`, `drop`, and `install`
still require matching process-registered extension code.

## Operational Copies

Backup, compact, and restore preserve `_zova_extensions` and extension-owned
tables through normal SQLite copying. When extension code is available, Zova
can verify the extension through its check hook.

Salvage support for extension-owned storage is deferred. Unknown extension
storage should be treated conservatively.

## Authoring Shape

Native Zig extension code provides a manifest and hooks:

```zig
const ext = zova.Extension{
    .manifest = .{
        .name = "my_ext",
        .version = "0.1.0",
        .storage_prefix = "_zova_ext_my_ext_",
        .zova_abi_min = "0.21.0",
        .capabilities = "sql",
    },
    .install = install,
    .check = check,
    .drop = drop,
    .register_sql = registerSql,
};

const registry = zova.ExtensionRegistry.init(&.{ext});
var db = try zova.Database.openWithExtensions("app.zova", registry);
```

The exact public authoring API may still change while v0.21 is in development.
The contract that should not change is the trust boundary: extension code comes
from the process, not from the database file.
