import pytest

import zova


def test_notifications_follow_transactions_and_sql_notify(tmp_path):
    path = tmp_path / "notifications.zova"
    with zova.Database.create(str(path)) as db:
        sub = db.listen("messages")

        db.notify("messages", "outside")
        note = sub.try_receive()
        assert note is not None
        assert note.channel == "messages"
        assert note.payload == "outside"
        assert note.sequence == 1
        assert note.dropped_before == 0
        assert sub.try_receive() is None

        db.begin_immediate()
        db.notify("messages", "committed")
        assert sub.try_receive() is None
        db.commit()
        assert sub.try_receive().payload == "committed"

        db.begin_immediate()
        db.notify("messages", "rolled-back")
        db.rollback()
        assert sub.try_receive() is None

        db.begin_immediate()
        db.savepoint("inner")
        db.notify("messages", "discarded-savepoint")
        db.rollback_to_savepoint("inner")
        db.notify("messages", "kept-savepoint")
        db.release_savepoint("inner")
        db.commit()
        assert sub.try_receive().payload == "kept-savepoint"
        assert sub.try_receive() is None

        with db.listen("sql") as sql_sub:
            with db.prepare("select zova_notify('sql', 'from-sql')") as stmt:
                assert stmt.step() == zova.Step.ROW
            assert sql_sub.try_receive().payload == "from-sql"

        sub.close()


def test_subscription_validation_and_close(tmp_path):
    path = tmp_path / "notification-close.zova"
    with zova.Database.create(str(path)) as db:
        with pytest.raises(zova.ZovaError) as exc:
            db.listen("_zova_private")
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"

        with pytest.raises(zova.ZovaError) as exc:
            db.notify("bad channel", "payload")
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"

        with pytest.raises(zova.ZovaError) as exc:
            db.notify("events", "x" * (64 * 1024 + 1))
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"

        sub = db.listen("events")
        with pytest.raises(zova.ZovaError) as exc:
            db.exec("select zova_notify('_zova_private', 'payload')")
        assert exc.value.status_name == "ZOVA_SQLITE_ERROR"
        assert sub.try_receive() is None

        sub.close()
        with pytest.raises(zova.ClosedHandleError):
            sub.try_receive()


def test_notification_object_metadata_workflow(tmp_path):
    path = tmp_path / "notification-object-workflow.zova"
    with zova.Database.create(str(path)) as db:
        db.exec("create table attachments(id integer primary key, object_id blob not null)")
        with db.listen("message:1:attachments") as sub:
            object_id = db.put_object(b"attachment bytes")

            db.begin_immediate()
            with db.prepare("insert into attachments(object_id) values (?1)") as stmt:
                stmt.bind_blob(1, bytes(object_id))
                assert stmt.step() == zova.Step.DONE
            db.notify("message:1:attachments", "changed")
            assert sub.try_receive() is None
            db.commit()

            note = sub.try_receive()
            assert note is not None
            assert note.payload == "changed"

            with db.prepare("select object_id from attachments") as stmt:
                assert stmt.step() == zova.Step.ROW
                stored_id = zova.ObjectId(stmt.column_blob(0))
            assert db.get_object(stored_id) == b"attachment bytes"


def test_in_memory_kv_batch_emits_one_aggregate_notification():
    with zova.Database.create_memory() as db:
        with db.listen("cache:search-results") as sub:
            db.begin_immediate()
            db.kv_put_many(b"search-results", [(b"result-1", b"one"), (b"result-2", b"two")])
            db.notify("cache:search-results", "generation:42")
            assert sub.try_receive() is None
            db.commit()

            note = sub.try_receive()
            assert note is not None
            assert note.channel == "cache:search-results"
            assert note.payload == "generation:42"
            assert note.sequence == 1
            assert sub.try_receive() is None

            assert db.kv_get(b"search-results", b"result-1") == b"one"


def test_notification_vector_metadata_workflow(tmp_path):
    path = tmp_path / "notification-vector-workflow.zova"
    with zova.Database.create(str(path)) as db:
        db.exec("create table chunks(id text primary key, vector_id text not null)")
        db.create_vector_collection(
            "chunks",
            zova.VectorCollectionOptions(2, zova.VectorMetric.L2, zova.VectorElementType.F32),
        )
        db.put_vector("chunks", "chunk:1", zova.VectorElementType.F32, [0.0, 0.0])

        with db.listen("vectors:chunks") as sub:
            db.begin_immediate()
            db.exec("insert into chunks(id, vector_id) values ('c1', 'chunk:1')")
            db.notify("vectors:chunks", "changed")
            assert sub.try_receive() is None
            db.commit()

            note = sub.try_receive()
            assert note is not None
            assert note.payload == "changed"
            assert db.search_vectors("chunks", zova.VectorElementType.F32, [0.0, 0.0], 1)[0].id == "chunk:1"
