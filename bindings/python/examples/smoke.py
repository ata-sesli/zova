from pathlib import Path
from tempfile import TemporaryDirectory

import zova


def expect_one_int(db: zova.Database, sql: str) -> int:
    with db.prepare(sql) as stmt:
        assert stmt.step() == zova.Step.ROW
        return stmt.column_int(0)


def main() -> None:
    print("zova", zova.__version__)

    with TemporaryDirectory() as tmp:
        path = Path(tmp) / "smoke.zova"

        print("records: create, insert, query")
        with zova.Database.create(str(path)) as db:
            db.exec("create table notes(id integer primary key, body text not null)")

            with db.prepare("insert into notes(body) values (?1)") as insert:
                for body in ["hello", "second"]:
                    insert.bind_text(1, body)
                    assert insert.step() == zova.Step.DONE
                    insert.reset()
                    insert.clear_bindings()

            assert db.last_insert_rowid() == 2
            assert db.changes() == 1
            assert expect_one_int(db, "select count(*) from notes") == 2

            with db.prepare("select body from notes where id = ?1") as stmt:
                stmt.bind_int(1, 1)
                assert stmt.step() == zova.Step.ROW
                assert stmt.column_name(0) == "body"
                assert stmt.column_text(0) == "hello"
                assert stmt.step() == zova.Step.DONE

            print("transactions: rollback")
            db.begin_immediate()
            db.exec("insert into notes(body) values ('rolled back')")
            db.rollback()
            assert expect_one_int(db, "select count(*) from notes") == 2

            print("objects: put, read range, manifest")
            object_id = db.put_object(b"hello from a smoke object")
            assert db.has_object(object_id)
            assert db.object_size(object_id) == 25
            assert db.read_object_range(object_id, 0, 5) == b"hello"
            assert db.object_manifest(object_id).object_id == object_id

            db.exec(
                "create table attachments("
                "id integer primary key, "
                "object_id blob not null)"
            )
            with db.prepare("insert into attachments(object_id) values (?1)") as stmt:
                stmt.bind_blob(1, bytes(object_id))
                assert stmt.step() == zova.Step.DONE

            print("vectors: create collection, insert, search")
            db.create_vector_collection(
                "chunks",
                zova.VectorCollectionOptions(2, zova.VectorMetric.L2),
            )
            db.put_vectors(
                "chunks",
                [
                    zova.VectorInput("near", [0.0, 0.0]),
                    zova.VectorInput("far", [10.0, 0.0]),
                ],
            )
            assert db.vector_collection_info("chunks").vector_count == 2
            results = db.search_vectors("chunks", [0.0, 0.0], 2)
            assert [result.id for result in results] == ["near", "far"]

        print("reopen: records, objects, vectors survived")
        with zova.Database.open(str(path)) as db:
            assert expect_one_int(db, "select count(*) from notes") == 2

            with db.prepare("select object_id from attachments where id = 1") as stmt:
                assert stmt.step() == zova.Step.ROW
                reloaded_object_id = zova.ObjectId(stmt.column_blob(0))
            assert db.get_object(reloaded_object_id) == b"hello from a smoke object"

            assert db.search_vectors("chunks", [0.0, 0.0], 1)[0].id == "near"

    print("ok")


if __name__ == "__main__":
    main()
