import math
import sqlite3
import struct

import pytest

import zova


def assert_distances_close(results, expected):
    assert [item.id for item in results] == [item[0] for item in expected]
    for result, (_, distance) in zip(results, expected):
        assert math.isclose(result.distance, distance, abs_tol=1e-6)


def test_vector_collection_lifecycle_crud_batch_and_delete(tmp_path):
    path = tmp_path / "vectors.zova"

    with zova.Database.create(str(path)) as db:
        db.exec("create table chunks(id text primary key, vector_id text not null)")
        options = zova.VectorCollectionOptions(2, zova.VectorMetric.L2)
        assert options.dimensions == 2
        assert options.metric == zova.VectorMetric.L2

        db.create_vector_collection("chunks", options)
        db.create_vector_collection("docs", zova.VectorCollectionOptions(3, zova.VectorMetric.DOT))
        assert db.has_vector_collection("chunks")

        info = db.vector_collection_info("chunks")
        assert isinstance(info, zova.VectorCollectionInfo)
        assert info.name == "chunks"
        assert info.dimensions == 2
        assert info.metric == zova.VectorMetric.L2
        assert info.vector_count == 0

        assert [item.name for item in db.list_vector_collections()] == ["chunks", "docs"]

        db.put_vectors(
            "chunks",
            [
                zova.VectorInput("a", [2.0, 0.0]),
                zova.VectorInput("b", (5.0, 0.0)),
                zova.VectorInput("a", [1.0, 0.0]),
            ],
        )
        db.put_vectors("chunks", [])
        assert db.has_vector("chunks", "a")

        vector = db.get_vector("chunks", "a")
        assert isinstance(vector, zova.Vector)
        assert vector.id == "a"
        assert vector.values == [1.0, 0.0]

        db.put_vector("chunks", "a", [4.0, 0.0])
        assert db.get_vector("chunks", "a").values == [4.0, 0.0]

        db.exec("insert into chunks(id, vector_id) values ('row-a', 'a')")
        db.delete_vector("chunks", "a")
        assert not db.has_vector("chunks", "a")
        with pytest.raises(zova.ZovaError) as exc:
            db.delete_vector("chunks", "a")
        assert exc.value.status_name == "ZOVA_VECTOR_NOT_FOUND"

        with db.prepare("select vector_id from chunks where id = 'row-a'") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "a"

        db.delete_vector_collection("chunks")
        with pytest.raises(zova.ZovaError) as exc:
            db.has_vector("chunks", "b")
        assert exc.value.status_name == "ZOVA_VECTOR_COLLECTION_NOT_FOUND"

        with db.prepare("select count(*) from chunks where vector_id = 'a'") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_int(0) == 1


def test_vector_search_variants(tmp_path):
    path = tmp_path / "search.zova"

    with zova.Database.create(str(path)) as db:
        db.create_vector_collection("l2", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
        db.put_vectors(
            "l2",
            [
                zova.VectorInput("source", [0.0, 0.0]),
                zova.VectorInput("near", [1.0, 0.0]),
                zova.VectorInput("tie-a", [0.0, 1.0]),
                zova.VectorInput("far", [3.0, 4.0]),
            ],
        )

        assert_distances_close(
            db.search_vectors("l2", [0.0, 0.0], 3),
            [("source", 0.0), ("near", 1.0), ("tie-a", 1.0)],
        )
        assert [item.id for item in db.search_vectors_in("l2", [0.0, 0.0], ["far", "near", "near", "missing"], 10)] == [
            "near",
            "far",
        ]

        by_id = db.search_vectors_by_id("l2", "source", 10)
        assert "source" not in [item.id for item in by_id]
        assert [item.id for item in by_id[:2]] == ["near", "tie-a"]

        assert [item.id for item in db.search_vectors_by_id_in("l2", "source", ["source", "far", "near"], 10)] == [
            "near",
            "far",
        ]
        assert [item.id for item in db.search_vectors_within("l2", [0.0, 0.0], 1.0, 10)] == [
            "source",
            "near",
            "tie-a",
        ]
        assert [item.id for item in db.search_vectors_in_within("l2", [0.0, 0.0], ["near", "far"], 1.0, 10)] == [
            "near"
        ]
        assert [item.id for item in db.search_vectors_by_id_within("l2", "source", 1.0, 10)] == [
            "near",
            "tie-a",
        ]
        assert [item.id for item in db.search_vectors_by_id_in_within("l2", "source", ["near", "far"], 1.0, 10)] == [
            "near"
        ]

        db.create_vector_collection("cosine", zova.VectorCollectionOptions(2, zova.VectorMetric.COSINE))
        db.put_vector("cosine", "x", [1.0, 0.0])
        db.put_vector("cosine", "diag", [1.0, 1.0])
        assert [item.id for item in db.search_vectors("cosine", [1.0, 0.0], 2)] == ["x", "diag"]

        db.create_vector_collection("dot", zova.VectorCollectionOptions(2, zova.VectorMetric.DOT))
        db.put_vector("dot", "low", [1.0, 0.0])
        db.put_vector("dot", "high", [3.0, 0.0])
        dot = db.search_vectors_within("dot", [1.0, 0.0], -2.0, 10)
        assert_distances_close(dot, [("high", -3.0)])

        with pytest.raises(zova.ZovaError) as exc:
            db.search_vectors("l2", [0.0], 1)
        assert exc.value.status_name == "ZOVA_VECTOR_DIMENSION_MISMATCH"

        with pytest.raises(ValueError):
            db.put_vector("l2", "bad\0id", [1.0, 2.0])


def test_vectors_survive_reopen_conversion_and_mix_with_records_objects(tmp_path):
    path = tmp_path / "mixed.zova"
    with zova.Database.create(str(path)) as db:
        db.exec(
            "create table chunks("
            "id text primary key, "
            "object_id blob not null, "
            "vector_id text not null, "
            "document_id text not null)"
        )
        object_id = db.put_object(b"metadata and bytes")
        db.create_vector_collection("chunks", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
        db.put_vector("chunks", "v1", [0.0, 0.0])
        db.put_vector("chunks", "v2", [1.0, 0.0])
        with db.prepare("insert into chunks(id, object_id, vector_id, document_id) values (?1, ?2, ?3, ?4)") as stmt:
            stmt.bind_text(1, "chunk-1")
            stmt.bind_blob(2, bytes(object_id))
            stmt.bind_text(3, "v1")
            stmt.bind_text(4, "doc-a")
            assert stmt.step() == zova.Step.DONE

    with zova.Database.open(str(path)) as db:
        assert db.vector_collection_info("chunks").vector_count == 2
        assert db.search_vectors("chunks", [0.0, 0.0], 1)[0].id == "v1"
        with db.prepare("select object_id from chunks where vector_id = ?1") as stmt:
            stmt.bind_text(1, "v1")
            assert stmt.step() == zova.Step.ROW
            assert db.get_object(zova.ObjectId(stmt.column_blob(0))) == b"metadata and bytes"

    source = tmp_path / "source.db"
    destination = tmp_path / "converted.zova"
    sql = sqlite3.connect(source)
    sql.execute("create table rows(id integer primary key, value text not null)")
    sql.execute("insert into rows(value) values ('converted')")
    sql.commit()
    sql.close()

    zova.convert_sqlite_to_zova(str(source), str(destination))
    with zova.Database.open(str(destination)) as db:
        db.create_vector_collection("converted_vectors", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
        db.put_vector("converted_vectors", "v", [1.0, 2.0])
        assert db.get_vector("converted_vectors", "v").values == [1.0, 2.0]
        with db.prepare("select count(*) from rows") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_int(0) == 1


def test_sql_native_vector_helpers_and_queries(tmp_path):
    path = tmp_path / "sql-vectors.zova"
    assert zova.encode_f32_le([1.0, -2.5]) == struct.pack("<ff", 1.0, -2.5)
    with pytest.raises(ValueError):
        zova.encode_f32_le([float("nan")])

    with zova.Database.create(str(path)) as db:
        db.exec("create table chunks(id text primary key, vector_id text not null, document_id text not null)")
        db.create_vector_collection("chunks", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
        db.put_vectors(
            "chunks",
            [
                zova.VectorInput("v1", [0.0, 0.0]),
                zova.VectorInput("v2", [1.0, 0.0]),
            ],
        )
        db.exec(
            "insert into chunks(id, vector_id, document_id) values "
            "('c1', 'v1', 'doc-a'), "
            "('c2', 'v2', 'doc-a')"
        )

        query_blob = zova.encode_f32_le([0.0, 0.0])
        with db.prepare(
            "select c.id, zova_vector_distance('chunks', c.vector_id, ?1) as distance "
            "from chunks as c "
            "where c.document_id = 'doc-a' "
            "order by distance, c.id "
            "limit 1"
        ) as stmt:
            stmt.bind_blob(1, query_blob)
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "c1"
            assert math.isclose(stmt.column_float(1), 0.0, abs_tol=1e-6)

        with db.prepare("select zova_vector_distance_by_id('chunks', 'v2', 'v1')") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert math.isclose(stmt.column_float(0), 1.0, abs_tol=1e-6)

        with db.prepare(
            "select c.id, s.distance "
            "from zova_vector_search as s "
            "join chunks as c on c.vector_id = s.vector_id "
            "where s.collection = 'chunks' "
            "and s.query_vector = ?1 "
            "and s.top_k = 2 "
            "order by s.rank"
        ) as stmt:
            stmt.bind_blob(1, query_blob)
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "c1"
            assert math.isclose(stmt.column_float(1), 0.0, abs_tol=1e-6)
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "c2"
