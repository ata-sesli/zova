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

In the current v0.23.0 model, all installed extensions are required. Opening a
database with installed extension metadata but without matching process code
fails during normal open. Diagnostic commands can still inspect the metadata so
they can explain what is missing.

Registry composition is validated before create, open, install, or check work
starts. Duplicate extension names or duplicate storage prefixes are invalid, and
external extensions cannot shadow bundled extensions such as `trgm`.

## Trust Boundary

Extension code is native trusted code. Treat it like application code linked
into the same process.

A `.zova` file may say which extensions it needs, but the application or CLI
process decides which extension code is available. Zova never loads code just
because a database asks for it.

Zova supports three process-owned extension sources in v0.23.0:

- bundled extensions shipped with Zova, such as `trgm`
- app-registered native Zig extensions supplied by the application process
- explicitly trusted local `.zovaext` bundle folders supplied by the user or app

Deferred for later work:

- extension signing
- marketplace or network fetching
- optional installed extensions
- high-level Rust, Go, or Python extension authoring APIs

## Trusted Local `.zovaext` Bundles

A dynamic extension bundle is a local folder ending in `.zovaext`.

Required bundle shape:

```text
my_ext.zovaext/
  extension.json
  libmy_ext
```

The library name is recorded in `extension.json`. The experimental builder uses
the platform dynamic-library convention: `my_ext.dll` on Windows,
`libmy_ext.dylib` on Apple platforms, and `libmy_ext.so` elsewhere. Whatever
name is chosen, the path must remain relative to the bundle and the native
artifact must be built against a compatible Zova extension ABI.

`extension.json` contains:

```json
{
  "name": "my_ext",
  "version": "0.1.0",
  "storage_prefix": "_zova_ext_my_ext_",
  "zova_abi_min": "0.21.0",
  "capabilities": "sql",
  "library": "libmy_ext",
  "entrypoint": "zova_extension_entry"
}
```

`entrypoint` is optional and defaults to `zova_extension_entry`. The library path
must be relative to the bundle, must not contain `..`, and must stay inside the
bundle.

Dynamic extensions are native trusted code. They must be built for the same
Zova/Zig extension ABI. Loading a bundle means running code in the current
process with the same trust level as the application.

Trust a bundle before loading it:

```sh
zova extension trust ./my_ext.zovaext
zova extension trusted
```

Trust records live at `$ZOVA_TRUST_STORE` when set, otherwise
`$XDG_CONFIG_HOME/zova/trusted_extensions.json`, otherwise
`$HOME/.config/zova/trusted_extensions.json`. A trust record stores the
canonical bundle path, extension identity, manifest hash, library hash, and
trust timestamp.

If `extension.json` or the native library changes, loading fails until the
bundle is trusted again.

Load trusted bundles explicitly for one CLI process:

```sh
zova --extension ./my_ext.zovaext extension install app.zova my_ext
zova --extension ./my_ext.zovaext check --deep app.zova
```

Zova never scans trusted bundles automatically. A `.zova` database can require
an extension by name, but it cannot make Zova load a library path. The process
opening the database must provide the bundle with `--extension` or with a
registry-aware native API.

C callers use the same trust boundary through the C ABI:

- `zova_extension_bundle_verify` checks a local bundle and entrypoint without
  writing trust.
- `zova_extension_bundle_trust` records the current manifest/library hashes in
  the selected trust store.
- `zova_extension_bundle_untrust` removes a trust record by identifier.
- `zova_database_create_with_extensions` and
  `zova_database_open_with_extensions` open a handle with explicitly supplied
  trusted bundle paths composed with Zova's bundled registry.

Opening with a bundle never trusts it automatically. If the bundle is missing,
untrusted, or has changed since trust was recorded, open/create fails before the
database handle is returned. Loaded bundle libraries stay alive until the C ABI
database handle is closed. After opening, C callers use the existing extension
lifecycle calls such as `zova_database_extension_install`,
`zova_database_extension_check`, `zova_database_extension_list`, and
`zova_database_extension_info`. SQL functions from an extension `register_sql`
hook are available on Zova-owned C ABI connections once that extension is
installed and on later opens when its bundle code is provided.

The registry is fixed for the lifetime of a database handle. To change the set
of available external bundles, close the handle and open/create another one with
the desired bundle list.

The staged v0.23.0 integration model is the combination of app-defined scalar
SQL callbacks and explicitly trusted `.zovaext` bundles. Zova does not expose a
raw `sqlite3 *` accessor as the extension path; code that needs SQL functions on
Zova-owned connections should use `zova_database_register_function`, trusted
extension bundles, or native Zig registry injection.

Remove trust by name or bundle path:

```sh
zova extension untrust my_ext
zova extension untrust ./my_ext.zovaext
```

## Experimental Bundle Builder

The v0.23 release includes an experimental producer-side CLI for
local Zig extensions. It is meant to remove the manual bundle-shape work while
the stable extension-authoring contract is still being designed.

Create a minimal Zig extension project:

```sh
zova extension scaffold ./sample_ext --name sample_ext --version 0.1.0
```

Build the native dynamic library with the same Zig package layout Zova uses:

```sh
zova extension build ./sample_ext
```

The experimental builder passes Zova's vendored SQLite include directory to Zig
because extension code that imports `zova.sqlite` needs `sqlite3.h` visible at
compile time. Manual bridge builds need the same include path.

Pack it into the existing `.zovaext` directory format:

```sh
zova extension pack ./sample_ext --out ./sample_ext.zovaext
```

Verify bundle metadata, library containment, hashes, and the entrypoint symbol:

```sh
zova extension verify ./sample_ext.zovaext
zova extension verify --smoke ./sample_ext.zovaext
```

`--smoke` opens the native library, verifies the configured entrypoint against
the bundle manifest, creates a temporary `.zova`, installs the extension, runs
the extension check hook, and reopens the temporary database with the same
loaded registry. It does not trust the bundle for later commands.
Trust and install remain explicit:

```sh
zova extension trust ./sample_ext.zovaext
zova --extension ./sample_ext.zovaext extension install app.zova sample_ext
```

The builder path expects the dynamic library to export the configured entrypoint
symbol, defaulting to `zova_extension_entry`. Empty libraries, missing libraries,
and missing entrypoint symbols fail during `pack` or `verify --smoke` before the
bundle can be trusted or installed.

For downstream bridge builds, `zig build-obj` is the simplest fallback shape:
link the produced object into the host and verify it is non-empty and exports
the expected C symbols. `zig build-lib -static` should produce a non-empty
archive with the same symbols; do not trust a static archive unless an explicit
symbol check passes. These object/static modes are diagnostics for host-owned
bridge builds, not new `zova extension build` modes.

## Bundled `trgm`

The first bundled extension is `trgm`.

Install it with the normal CLI build:

```sh
zova extension install app.zova trgm
```

After install, default Zova opens know about the bundled code and register the
SQL surface:

```sql
zova_trgm_similarity(a text, b text)
zova_trgm_create_index(index_name text)
zova_trgm_drop_index(index_name text)
zova_trgm_put(index_name, document_id, target_type, target_namespace, target_ref, text)
zova_trgm_delete(index_name, document_id)
zova_trgm_search
```

`trgm` stores no raw indexed text. It stores a normalized length, a SHA-256 text
hash, unique trigram counts, and postings. Search ranks with Jaccard similarity
over byte trigrams and orders ties by `document_id`.

`target_namespace` and `target_ref` may be null for app-owned targets such as
`record`, `entity`, `fact`, `concept`, and `external`. Zova-owned targets
(`object`, `object_chunk`, `vector`, and `graph`) require enough reference data
for Zova to validate the target.

Object and vector targets may live in bound object/vector stores. `trgm` follows
normal Zova target validation through the opened database, while the extension
registry and `_zova_ext_trgm_*` index tables remain in the main database.

Use `trgm` for fuzzy target lookup:

```sql
select zova_trgm_create_index('messages');
select zova_trgm_put(
  'messages',
  'message:123',
  'record',
  'messages',
  '123',
  'attachment upload failed'
);

select document_id, target_type, target_namespace, target_ref, score
from zova_trgm_search
where index_name = 'messages'
  and query = 'attachement failed'
  and threshold = 0.20
  and "limit" = 10
order by rank;
```

This is different from SQLite FTS. FTS is for tokenized full-text search:
documents, terms, phrase matching, and ranking by textual relevance. `trgm` is
for typo-tolerant matching of short labels, filenames, identifiers, titles, or
target records. It also differs from vectors: vectors are for semantic
similarity, while trigram similarity is lexical and deterministic.

Accepted target types are `record`, `object`, `object_chunk`, `vector`, `graph`,
`entity`, `fact`, `concept`, and `external`. Zova validates object IDs, object
chunk IDs, vectors, and graph nodes when possible. It does not validate
arbitrary application SQL row existence.

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

`zova_abi_min` must be a canonical `major.minor.patch` version. Zova rejects a
manifest when its ABI major differs from the host or its minimum version is
newer than the host. Because the extension ABI is still pre-1.0, extension
authors should rebuild and retest bundles for every Zova minor release.

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

Read-only opens still register connection-local extension SQL hooks and run
extension checks. Hooks and checks used during read-only open must not write
schema or data; SQLite's read-only error path rejects any attempted write.

If `register_sql` fails during install, the install savepoint rolls back the
extension metadata and private storage created by that install. If it fails
during normal open, the handle is not returned.

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
Extensions can still refer to objects and vectors in bound stores through
normal target refs; the extension-owned tables themselves are not stored in the
bound store.

## Diagnostics

`zova check --deep` and `zova doctor` report extension issues without printing
private schema SQL or indexed/private data.

They can inspect installed metadata even when normal open fails because required
extension code is unavailable.

`zova extension list` and `zova extension info` can also inspect installed
metadata without registered code. `zova extension check`, `drop`, and `install`
still require matching process-registered extension code.

## Binding Lifecycle APIs

The C ABI, Rust, Go, and Python bindings can manage extensions that are already
registered in the current process. In the default Zova build that means bundled
extensions such as `trgm`: install, list, info, check, check all, and drop.

Those binding APIs do not make `.zova` files executable. C callers can supply
trusted `.zovaext` bundles at handle create/open time; high-level Rust, Go, and
Python dynamic-loading APIs are still deferred.

When a dynamic bundle is missing or untrusted, diagnostics point back to the
process boundary: supply the bundle with `--extension <bundle.zovaext>` for that
command, or run `zova extension trust <bundle.zovaext>` after verifying the
local code is expected.

The binding example files include an `extensions` example that installs `trgm`,
indexes records, object filenames, vector chunks, and graph entities, then uses
normal prepared statements to query `zova_trgm_search`.

Extension operations do not auto-notify listeners. Applications or trusted
extension workflows should call Zova's same-process `notify` API explicitly when
they want listeners to react to an indexing workflow.

## C ABI Scalar SQL Functions

The v0.23 release exposes a controlled C ABI path for registering scalar
SQL functions on a Zova-owned connection:

```c
zova_sql_function_register_request request = {
    .db = db,
    .name = "app_score",
    .arity = 1,
    .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC,
    .user_data = state,
    .callback = app_score_callback,
    .destroy = app_score_destroy,
};
zova_database_register_function(&request);
```

Function names are ASCII identifiers, 1-64 bytes, and may not use `zova_` or
`_zova_` prefixes. Arity is `-1` for varargs or `0..127` for fixed arity.
Registration is per open SQLite connection; registering a function on one
`zova_database` handle does not install it on other handles. Functions
registered on an application-owned raw SQLite handle are not automatically
present on Zova-owned handles.

The callback receives borrowed `zova_sql_value` arguments and fills one
`zova_sql_result`. Zova copies text, blob, and error bytes before SQLite
observes the result, so result buffers only need to stay valid until the
callback returns. Argument pointers are valid only during the callback.

See `examples/c_callbacks/` for small C snippets covering deterministic scalar
registration, text/blob arguments and results, and callback error propagation.

Callbacks run while the database handle is inside Zova's serialization boundary.
They must not re-enter the same `zova_database` handle. The destructor, when
provided, runs when SQLite releases the registered function, normally during
database close.

Function flags are caller-selected. Zova does not silently add deterministic,
direct-only, innocuous, or subtype behavior. Aggregate/window functions, SQLite
subtype support, and unregister support are deferred beyond v0.23.
Callbacks that should not run from schema contexts such as generated columns,
indexes, triggers, or views should be registered with
`ZOVA_SQL_FUNCTION_DIRECT_ONLY`.

This iteration exposes the low-level C ABI and `zova-sys` declarations only.
Safe high-level Rust, Go, and Python callback APIs are deferred beyond v0.23.

## Operational Copies

Backup, compact, and restore preserve `_zova_extensions` and extension-owned
tables through normal SQLite copying. When extension code is available, Zova
can verify the extension through its check hook.

If required extension code is unavailable during verification, the operation
fails clearly instead of silently treating extension-owned storage as healthy.
Use diagnostics with the same process registry or CLI `--extension` bundle list
that the application will use.

SQLite-to-Zova conversion does not install external extensions and never loads
extension code from the source database. It copies normal application tables,
indexes, views, and triggers into a new `.zova` file, then initializes Zova core
metadata. Source objects whose names start with `_zova_`, including
`_zova_ext_*`, are rejected as reserved and the failed destination is removed.
Application tables with extension-adjacent names outside that reserved prefix
remain ordinary app-owned SQL tables.

Salvage support is hook-based. Zova core never copies `_zova_ext_*` tables by
guessing their meaning. During salvage, core asks installed extension code for
an optional salvage hook. The hook may copy, rebuild, or skip its own storage.

If extension code is unavailable, or if the extension has no salvage hook, Zova
skips that extension's private storage and reports bounded skipped counts. The
destination is not marked as having that extension installed unless the hook
explicitly rebuilt enough storage and asks Zova to write installed metadata.

In v0.23.0, the bundled `trgm` extension has a valid-subset salvage hook. When
the source has required trgm private schema and metadata, the hook copies valid
indexes, documents, and postings, rebuilds derived term rows, and asks Zova to
mark `trgm` installed in the destination only after the rebuilt storage passes
the extension check. It skips unrecoverable trgm storage without leaving private
tables behind and without printing indexed text, term bytes, or private schema
SQL.

## Moving Databases That Require Extensions

When you copy or share a `.zova` file with installed extensions, move the
required extension code along with the application or document which bundled
extensions are required.

Bundled extensions such as `trgm` are available in the normal Zova CLI and
default native opens. Dynamic local extensions are not stored in the database;
the receiving process must trust and provide the `.zovaext` bundle again:

```sh
zova extension trust ./my_ext.zovaext
zova --extension ./my_ext.zovaext doctor app.zova
```

A database cannot force another machine to load extension code. Missing code is
reported as an extension health issue.

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

The v0.23 binding APIs can manage extensions already present in the process
registry, such as bundled `trgm`, and the C ABI can open handles with explicitly
trusted `.zovaext` bundles. Stable high-level Rust, Go, and Python extension
authoring APIs are still deferred. The stable contract is the trust boundary:
extension code comes from the process, not from the database file.

Use Zig `comptime` helpers where they make extension glue safer, such as
validating function signatures or generating repetitive registration wrappers.
Keep direct SQLite calls and the core `zova.sqlite` layer thin and explicit so
downstream bridge builds remain easy to inspect and debug.

See `examples/zig_bridge/` for a minimal bridge that exposes one C-callable
smoke function while registering SQL on a Zova-owned connection through a Zig
extension registry.

## Native Artifact Notes

Native extension artifacts must be built for the target platform and a
compatible Zova extension ABI. On macOS, build extension bundles and bridge
objects with the same deployment-target policy used by the host application and
Zova release artifacts. A library built for a newer macOS deployment target may
link with warnings or fail in older host deployments.

The current release workflow keeps produced Zova artifacts on the existing
platform matrix. External extension builders should treat deployment target,
architecture, and ABI compatibility as part of their own release contract.

## v0.23.0 Stability Limits

v0.23.0 is the first downstream extension-platform release. The stable boundary
is controlled scalar SQL callbacks through the C ABI, low-level `zova-sys`
declarations, trusted local `.zovaext` bundle loading, and Zig registry
injection for native hosts.

Deferred from this release: aggregate/window SQL callbacks, SQLite subtype
support, unregister APIs, raw `sqlite3 *` exposure as the normal extension path,
safe high-level Rust callbacks, Go callbacks, and Python callbacks.
