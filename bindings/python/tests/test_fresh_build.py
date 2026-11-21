import pytest

import zova

SCHEMA = """
create table files(id integer primary key, path text not null, size real, body blob);
create index files_path on files(path);
create virtual table bodies using fts5(body);
"""


def count(db, sql):
    statement = db.prepare(sql)
    assert statement.step() == zova.Step.ROW
    value = statement.column_int(0)
    statement.close()
    return value


def prepared(db):
    db.exec(SCHEMA)
    db.create_vector_collection(
        "embeddings", zova.VectorCollectionOptions(2, zova.VectorMetric.L2, zova.VectorElementType.F32)
    )


def test_fresh_build_commits_every_target_together():
    with zova.Database.create_memory() as db:
        prepared(db)
        build = db.begin_fresh_build()
        build.table_rows(
            "files",
            ["id", "path", "size", "body"],
            [(1, "a.rs", 1.5, b"\x00a"), [2, "b.rs", None, bytearray(b"b")]],
        )
        build.fts_rows("bodies", ["body"], [("fn main",)])
        build.graph(
            "code",
            [
                zova.GraphFreshNodeInput("a.rs", "file", zova.GraphTargetType.NONE),
                zova.GraphFreshNodeInput("b.rs", "file", zova.GraphTargetType.NONE),
            ],
            [zova.GraphFreshEdgeInput(0, "imports", 1, b"w")],
        )
        build.vectors("embeddings", [zova.VectorInput("a.rs", zova.VectorElementType.F32, [1.0, 0.0])])
        # The session blocks every other call on the handle.
        with pytest.raises(zova.ZovaError):
            db.exec("select 1")
        result = build.finish()
        assert len(result.node_keys) == 2 and len(result.edge_keys) == 1
        profile = result.profile
        assert (profile.table_rows, profile.fts_rows, profile.vector_rows) == (2, 1, 1)
        assert profile.payload_bytes == 1

        assert count(db, "select count(*) from files") == 2
        assert count(db, "select count(*) from bodies where bodies match 'main'") == 1
        assert db.get_graph_edge_payloads("code", result.edge_keys) == [b"w"]
        assert db.has_vector("embeddings", "a.rs")

        with pytest.raises(zova.ZovaError) as error:
            build.abort()
        assert error.value.status_name == "ZOVA_MISUSE"


def test_failed_aborted_and_closed_sessions_roll_back():
    with zova.Database.create_memory() as db:
        prepared(db)

        build = db.begin_fresh_build()
        build.table_rows("files", ["id", "path"], [(1, "a.rs")])
        with pytest.raises(ValueError):
            build.table_rows("files", ["id", "path"], [(2,)])
        with pytest.raises(zova.ZovaError):
            build.table_rows("files", ["id", "path"], [(3, "c.rs")])
        build.close()
        assert count(db, "select count(*) from files") == 0

        build = db.begin_fresh_build()
        with pytest.raises(TypeError):
            build.table_rows("files", ["id", "path"], [(1, object())])
        build.close()

        build = db.begin_fresh_build()
        build.table_rows("files", ["id", "path"], [(1, "a.rs")])
        build.abort()
        assert count(db, "select count(*) from files") == 0

        with db.begin_fresh_build() as build:
            build.table_rows("files", ["id", "path"], [(1, "a.rs")])
        assert count(db, "select count(*) from files") == 0
        with pytest.raises(zova.ClosedHandleError):
            build.finish()

        # A native failure also ends the session.
        build = db.begin_fresh_build()
        with pytest.raises(zova.ZovaError):
            build.table_rows("missing_table", ["id"], [(1,)])
        with pytest.raises(zova.ZovaError):
            build.finish()
        build.close()
        db.exec("select 1")


def test_session_keeps_closed_database_alive_until_released():
    db = zova.Database.create_memory()
    prepared(db)
    build = db.begin_fresh_build()
    db.close()
    build.table_rows("files", ["id", "path"], [(1, "a.rs")])
    assert build.finish().profile.table_rows == 1
    build.close()
