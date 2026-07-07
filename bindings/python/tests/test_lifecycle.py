import sqlite3

import pytest

import zova


def test_import_and_error_mapping(tmp_path):
    assert zova.__version__ == "0.21.2"

    with pytest.raises(zova.ZovaError) as exc:
        zova.Database.create(str(tmp_path / "plain.db"))
    assert exc.value.status_name == "ZOVA_NOT_ZOVA_PATH"
    assert exc.value.status is not None

    with pytest.raises(ValueError):
        zova.Database.create("bad\0path.zova")


def test_create_open_exec_prepare_and_context_managers(tmp_path):
    path = tmp_path / "records.zova"

    with zova.Database.create(str(path)) as db:
        db.exec("create table records(id integer primary key, name text not null, payload blob)")
        with db.prepare("insert into records(name, payload) values (:name, :payload)") as stmt:
            assert stmt.parameter_count() == 2
            assert stmt.parameter_index(":name") == 1
            assert stmt.parameter_index(":missing") is None
            stmt.bind_text(1, "alpha")
            stmt.bind_blob(2, b"\x00bytes")
            assert stmt.step() == zova.Step.DONE
        assert db.last_insert_rowid() == 1
        assert db.changes() == 1
        assert db.total_changes() >= 1

    with zova.Database.open(str(path)) as db:
        with db.prepare("select id, name, payload from records where name = ?1") as stmt:
            stmt.bind_text(1, "alpha")
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_count() == 3
            assert stmt.column_name(0) == "id"
            assert stmt.column_name(1) == "name"
            assert stmt.column_name(2) == "payload"
            assert stmt.column_type(0) == zova.ColumnType.INTEGER
            assert stmt.column_int(0) == 1
            assert stmt.column_text(1) == "alpha"
            assert stmt.column_blob(2) == b"\x00bytes"
            assert stmt.step() == zova.Step.DONE


def test_bundled_trgm_extension_sql_surface_works_after_reopen(tmp_path):
    path = tmp_path / "trgm.zova"

    with zova.Database.create(str(path)) as db:
        _install_trgm_fixture(db)

    with zova.Database.open(str(path)) as db:
        with db.prepare("select zova_trgm_create_index('messages')") as stmt:
            assert stmt.step() == zova.Step.ROW

        with db.prepare(
            "select zova_trgm_put('messages', ?1, 'record', 'messages', ?2, ?3)"
        ) as stmt:
            stmt.bind_text(1, "message:123")
            stmt.bind_text(2, "123")
            stmt.bind_text(3, "attachment upload failed")
            assert stmt.step() == zova.Step.ROW

        with db.prepare(
            """
            select document_id, score
            from zova_trgm_search
            where index_name = 'messages'
              and query = ?1
              and "limit" = 1
            order by rank
            """
        ) as stmt:
            stmt.bind_text(1, "attachement failed")
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "message:123"
            assert stmt.column_float(1) > 0.20


def test_extension_lifecycle_methods_manage_bundled_trgm(tmp_path):
    path = tmp_path / "extensions.zova"

    with zova.Database.create(str(path)) as db:
        assert db.list_extensions() == []

        with pytest.raises(zova.ZovaError) as exc:
            db.install_extension("missing_ext")
        assert exc.value.status_name == "ZOVA_EXTENSION_NOT_FOUND"

        db.install_extension("trgm")
        with pytest.raises(zova.ZovaError) as exc:
            db.install_extension("trgm")
        assert exc.value.status_name == "ZOVA_EXTENSION_EXISTS"

        info = db.extension_info("trgm")
        assert isinstance(info, zova.ExtensionInfo)
        assert info.name == "trgm"
        assert info.storage_prefix == "_zova_ext_trgm_"
        assert info.capabilities == "sql,trgm"
        assert info.required is True
        assert info.installed_at_unix > 0
        assert "trgm" in info.manifest_json
        with pytest.raises(AttributeError):
            info.name = "changed"

        extensions = db.list_extensions()
        assert [extension.name for extension in extensions] == ["trgm"]
        db.check_extension("trgm")
        db.check_extensions()

        with db.prepare("select zova_trgm_create_index('messages')") as stmt:
            assert stmt.step() == zova.Step.ROW

        db.drop_extension("trgm")
        with pytest.raises(zova.ZovaError) as exc:
            db.extension_info("trgm")
        assert exc.value.status_name == "ZOVA_EXTENSION_NOT_FOUND"

        with pytest.raises(TypeError):
            db.install_extension(123)


def _install_trgm_fixture(db):
    db.exec(
        """
        insert into _zova_extensions
            (name, version, storage_prefix, zova_abi_min, capabilities, required,
             installed_at_unix, manifest_json)
        values ('trgm', '0.1.0', '_zova_ext_trgm_', '0.21.0', 'sql,trgm', 1,
                0, '{"extension":"trgm","version":"0.1.0"}')
        """
    )
    db.exec("create table _zova_ext_trgm_meta (key text primary key, value text not null)")
    db.exec(
        """
        insert into _zova_ext_trgm_meta (key, value)
        values ('schema_version', '1'), ('extension_version', '0.1.0')
        """
    )
    db.exec(
        """
        create table _zova_ext_trgm_indexes (
            name text primary key,
            created_order integer not null unique
        )
        """
    )
    db.exec(
        """
        create table _zova_ext_trgm_documents (
            index_name text not null,
            document_id text not null,
            target_type text not null,
            target_namespace text,
            target_ref text,
            normalized_len integer not null,
            text_hash blob not null check (length(text_hash) = 32),
            term_count integer not null,
            updated_at_unix integer not null,
            primary key (index_name, document_id)
        )
        """
    )
    db.exec(
        """
        create table _zova_ext_trgm_terms (
            index_name text not null,
            term blob not null check (length(term) = 3),
            document_count integer not null,
            primary key (index_name, term)
        )
        """
    )
    db.exec(
        """
        create table _zova_ext_trgm_postings (
            index_name text not null,
            term blob not null check (length(term) = 3),
            document_id text not null,
            count integer not null,
            primary key (index_name, term, document_id)
        )
        """
    )


def test_statement_round_trips_types_reset_clear_and_nulls(tmp_path):
    path = tmp_path / "types.zova"
    db = zova.Database.create(str(path))
    db.exec(
        """
        create table values_table(
            i integer,
            f real,
            n text,
            empty_text text,
            text_value text,
            empty_blob blob,
            blob_value blob
        )
        """
    )

    stmt = db.prepare("insert into values_table values (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
    stmt.bind_int(1, -7)
    stmt.bind_float(2, 3.5)
    stmt.bind_null(3)
    stmt.bind_text(4, "")
    stmt.bind_text(5, "hello")
    stmt.bind_blob(6, b"")
    stmt.bind_blob(7, memoryview(b"\x01\x02\x03"))
    assert stmt.step() == zova.Step.DONE
    stmt.close()

    query = db.prepare("select * from values_table")
    assert query.step() == zova.Step.ROW
    assert query.column_int(0) == -7
    assert query.column_float(1) == 3.5
    assert query.column_type(2) == zova.ColumnType.NULL
    assert query.column_text(2) is None
    assert query.column_text(3) == ""
    assert query.column_text(4) == "hello"
    assert query.column_blob(5) == b""
    assert query.column_blob(6) == b"\x01\x02\x03"
    query.close()

    reset = db.prepare("select ?1")
    reset.bind_int(1, 99)
    assert reset.step() == zova.Step.ROW
    assert reset.column_int(0) == 99
    reset.reset()
    assert reset.step() == zova.Step.ROW
    assert reset.column_int(0) == 99
    reset.reset()
    reset.clear_bindings()
    assert reset.step() == zova.Step.ROW
    assert reset.column_type(0) == zova.ColumnType.NULL
    reset.close()
    db.close()

    with pytest.raises(zova.ClosedHandleError):
        db.exec("select 1")
    with pytest.raises(zova.ClosedHandleError):
        reset.step()


def test_transactions_vacuum_and_conversion(tmp_path):
    path = tmp_path / "tx.zova"
    db = zova.Database.create(str(path))
    db.exec("create table tx(id integer primary key, value text)")

    db.begin()
    db.exec("insert into tx(value) values ('commit')")
    db.commit()

    db.begin_immediate()
    db.exec("insert into tx(value) values ('rollback')")
    db.rollback()

    with db.prepare("select count(*) from tx") as stmt:
        assert stmt.step() == zova.Step.ROW
        assert stmt.column_int(0) == 1

    db.vacuum()
    db.close()

    source = tmp_path / "source.db"
    destination = tmp_path / "converted.zova"
    sql = sqlite3.connect(source)
    sql.execute("create table notes(id integer primary key, body text not null)")
    sql.execute("insert into notes(body) values ('from sqlite')")
    sql.commit()
    sql.close()

    zova.convert_sqlite_to_zova(str(source), str(destination))
    with zova.Database.open(str(destination)) as converted:
        with converted.prepare("select body from notes where id = ?1") as stmt:
            stmt.bind_int(1, 1)
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "from sqlite"


def test_savepoints_rollback_release_and_validate_names(tmp_path):
    path = tmp_path / "savepoints.zova"
    with zova.Database.create(str(path)) as db:
        db.exec("create table tx(id integer primary key, value text)")
        db.begin_immediate()
        db.exec("insert into tx(value) values ('outer')")

        db.savepoint("sp_vectors")
        db.exec("insert into tx(value) values ('rolled back')")
        with pytest.raises(zova.ZovaError) as exc:
            db.put_object(b"blocked inside savepoint")
        assert exc.value.status_name == "ZOVA_OBJECT_TRANSACTION_ACTIVE"
        db.create_vector_collection(
            "temporary_vectors",
            zova.VectorCollectionOptions(2, zova.VectorMetric.L2),
        )
        db.put_vector("temporary_vectors", "v1", [1.0, 2.0])
        db.rollback_to_savepoint("sp_vectors")
        db.release_savepoint("sp_vectors")
        assert not db.has_vector_collection("temporary_vectors")

        db.savepoint("sp_release")
        db.exec("insert into tx(value) values ('kept')")
        db.release_savepoint("sp_release")
        db.commit()

        with db.prepare("select count(*) from tx where value != 'rolled back'") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_int(0) == 2

        with pytest.raises(zova.ZovaError) as exc:
            db.savepoint("bad name")
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"

        with pytest.raises(zova.ZovaError) as exc:
            db.release_savepoint("missing_sp")
        assert "no such savepoint" in str(exc.value)

        with db.savepoint_context("sp_scoped_keep") as scoped_db:
            assert scoped_db is db
            db.exec("insert into tx(value) values ('kept scoped')")

        with pytest.raises(zova.ZovaError):
            with db.savepoint_context("sp_scoped_fail"):
                db.exec("insert into tx(value) values ('rolled back scoped')")
                db.exec("select * from missing_table")

        with pytest.raises(zova.ZovaError) as exc:
            with db.savepoint_context("bad name"):
                db.exec("insert into tx(value) values ('not invoked')")
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"

        with db.savepoint_context("sp_outer"):
            db.exec("insert into tx(value) values ('outer scoped')")
            with db.savepoint_context("sp_inner"):
                db.exec("insert into tx(value) values ('inner scoped')")

        with pytest.raises(RuntimeError):
            with db.savepoint_context("sp_python_error"):
                db.exec("insert into tx(value) values ('rolled back python')")
                raise RuntimeError("boom")

        with db.prepare(
            "select count(*) from tx where value in ('kept scoped', 'outer scoped', 'inner scoped')"
        ) as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_int(0) == 3

        with db.prepare(
            "select count(*) from tx where value like '%rolled back%' or value = 'not invoked'"
        ) as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_int(0) == 0


def test_backup_compact_and_restore(tmp_path):
    source = tmp_path / "ops-source.zova"
    backup = tmp_path / "ops-backup.zova"
    compact = tmp_path / "ops-compact.zova"
    restored = tmp_path / "ops-restored.zova"
    no_verify = tmp_path / "ops-no-verify.zova"
    payload = b"python operational object bytes"

    with zova.Database.create(str(source)) as db:
        db.exec("create table records(id integer primary key, body text not null)")
        db.exec("insert into records(body) values ('kept')")
        object_id = db.put_object(payload)
        db.create_vector_collection(
            "chunks",
            zova.VectorCollectionOptions(2, zova.VectorMetric.L2),
        )
        db.put_vector("chunks", "near", [0.0, 0.0])
        db.put_vector("chunks", "far", [10.0, 0.0])

        db.backup_to(str(backup))
        db.compact_to(str(compact))
        db.backup_to(str(no_verify), verify=False)

        with pytest.raises(zova.ZovaError) as exc:
            db.backup_to(str(backup))
        assert exc.value.status_name == "ZOVA_DESTINATION_EXISTS"

        with pytest.raises(zova.ZovaError) as exc:
            db.compact_to(str(tmp_path / "bad-destination.db"))
        assert exc.value.status_name == "ZOVA_NOT_ZOVA_PATH"

    zova.restore_backup(str(backup), str(restored))
    with pytest.raises(zova.ZovaError) as exc:
        zova.restore_backup(str(tmp_path / "bad-source.db"), str(tmp_path / "bad-restore.zova"))
    assert exc.value.status_name == "ZOVA_NOT_ZOVA_PATH"

    for copy in (backup, compact, restored, no_verify):
        with zova.Database.open(str(copy)) as db:
            with db.prepare("select body from records where id = 1") as stmt:
                assert stmt.step() == zova.Step.ROW
                assert stmt.column_text(0) == "kept"
            assert db.get_object(object_id) == payload
            results = db.search_vectors("chunks", [0.0, 0.0], 2)
            assert results[0].id == "near"
            with db.prepare("select zova_vector_distance('chunks', 'near', ?1)") as stmt:
                stmt.bind_blob(1, zova.encode_f32_le([0.0, 0.0]))
                assert stmt.step() == zova.Step.ROW
                assert stmt.column_float(0) == 0.0


def test_read_only_open_and_busy_timeout(tmp_path):
    path = tmp_path / "readonly.zova"
    with zova.Database.create(str(path)) as db:
        db.exec("create table notes(id integer primary key, body text not null)")
        db.exec("insert into notes(body) values ('kept')")

    with zova.Database.open(str(path), read_only=True, busy_timeout_ms=1) as db:
        db.set_busy_timeout(0)
        db.set_busy_timeout(2)
        with db.prepare("select body from notes") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "kept"

        with pytest.raises(zova.ZovaError) as exc:
            db.exec("insert into notes(body) values ('blocked')")
        assert exc.value.status_name == "ZOVA_READ_ONLY"


def test_python_errors_copy_diagnostics_immediately(tmp_path):
    path = tmp_path / "diagnostics.zova"
    with zova.Database.create(str(path)) as db:
        with pytest.raises(zova.ZovaError) as exc:
            db.exec("select * from no_such_table")
        copied_message = str(exc.value)
        assert exc.value.status_name == "ZOVA_SQLITE_ERROR"
        assert "no_such_table" in copied_message

        db.exec("create table after_error(id integer)")
        assert exc.value.status_name == "ZOVA_SQLITE_ERROR"
        assert "no_such_table" in str(exc.value)
