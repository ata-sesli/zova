# SQLite App To Zova App Migration Guide

Zova can copy an existing SQLite database into a new `.zova` file. Conversion
preserves user SQL tables, rows, indexes, views, and triggers, then initializes
Zova's private schema beside them.

Use this guide when an app already has SQLite records and wants to add managed
objects, vectors, backup, compact copy, diagnostics, and salvage without adding
a server.

## What Changes

- Your SQL tables remain application-owned.
- Your existing rows remain normal SQLite rows.
- Zova adds private `_zova_*` tables for objects and vectors.
- Object bytes move into Zova only when your app writes them through object APIs.
- Vector values move into Zova only when your app writes them through vector APIs.
- Existing BLOB columns are not automatically converted into Zova objects.
- Existing embedding columns are not automatically converted into Zova vectors.

## Migration Shape

1. Back up the original SQLite file.
2. Convert into a new `.zova` file.
3. Open the `.zova` file through Zova.
4. Keep existing record queries as SQL.
5. Add `object_id` or `vector_id` columns to user tables when needed.
6. Write new object bytes through Zova object APIs.
7. Write new vectors through Zova vector APIs.
8. Run `zova check --deep`.
9. Keep the old SQLite file until the app migration is proven.

## Conversion APIs

Zig:

```zig
try zova.convertSqliteToZova("app.sqlite", "app.zova");
```

Rust:

```rust
zova::Database::convert_sqlite_to_zova("app.sqlite", "app.zova")?;
```

Go:

```go
err := zova.ConvertSqliteToZova("app.sqlite", "app.zova")
```

Python:

```python
zova.convert_sqlite_to_zova("app.sqlite", "app.zova")
```

## Schema Strategy

Store Zova references in your own tables:

```sql
alter table attachments add column object_id blob;
alter table chunks add column vector_id text;
```

Use SQL for metadata:

```sql
create table attachments(
  id integer primary key,
  filename text not null,
  content_type text,
  object_id blob not null
);
```

Use Zova for the bytes:

```rust
let object_id = db.put_object(bytes)?;
```

Use SQL for vector metadata:

```sql
create table chunks(
  id integer primary key,
  document_id integer not null,
  body text not null,
  vector_id text not null unique
);
```

Use Zova for vector values:

```rust
db.put_vector("chunks", "chunk:42", &embedding)?;
```

## Query Pattern

Use SQL to find the application rows, then use Zova APIs for object bytes or
vector values.

For object metadata:

```sql
select id, filename, object_id
from attachments
where id = ?1;
```

Then read the object:

```rust
let bytes = db.get_object(object_id)?;
```

For vector search, keep metadata in SQL and let Zova rank vector ids.

SQL-native vector search can join results back to your user tables:

```sql
select
  c.id,
  c.document_id,
  c.body,
  s.distance
from zova_vector_search as s
join chunks as c on c.vector_id = s.vector_id
where s.collection = 'chunks'
  and s.query_vector = ?1
  and s.top_k = 10
order by s.rank;
```

For SQL-filter-first workflows, filter in SQL and rank only matching rows:

```sql
select
  c.id,
  c.body,
  zova_vector_distance('chunks', c.vector_id, ?1) as distance
from chunks as c
where c.document_id = ?2
order by distance
limit 10;
```

## Transactions And Writers

SQL transactions and savepoints are available through Zova's database APIs.
Use them for user table changes and metadata updates.

Object mutation APIs own their own transaction policy. In current Zova releases,
object writes, object deletes, and `ObjectWriter.finish` can reject active
transaction/savepoint stacks. Keep long-running object writes outside explicit
SQL transaction scopes, then store the resulting `object_id` in user SQL.

A practical flow is:

1. Write object bytes through Zova and get an `ObjectId`.
2. Begin a SQL transaction.
3. Insert or update the user row that references the object id.
4. Commit the SQL transaction.
5. Run `zova check --deep` in tests or operational validation.

## Safety Checks

Run:

```sh
zova check --deep app.zova
zova doctor app.zova
```

For operational copies:

```sh
zova backup app.zova app.backup.zova
zova compact app.zova app.compact.zova
```

## Common Mistakes

- Do not rename `app.sqlite` to `app.zova` and expect it to become a Zova file.
- Do not edit `_zova_*` tables directly.
- Do not store app metadata in Zova vector collections.
- Do not expect object deletion to clean user SQL references.
- Do not expect file size to shrink after deletes without vacuum or compact copy.
- Do not parse CLI human text as a binding API contract.

## Do Not Migrate Yet If

Wait before moving a production app to Zova if:

- you do not have an export, backup, or rollback path,
- you need a stable 1.0 file format guarantee today,
- you need ANN indexes for million-scale vector search,
- you need TypeScript or Swift bindings right now,
- you need platform wheels for Python without a local native build,
- you need Zova to automatically repair damaged production files in place.

## Rollback Plan

Keep the original SQLite file. Conversion writes a new destination and does not
mutate the source. If migration fails, point the app back to the original file.

For app releases, ship an export/import or backup story before replacing a
production database.
