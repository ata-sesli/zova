import zova


def test_kv_crud_preserves_exact_bytes(tmp_path):
    path = tmp_path / "kv.zova"
    with zova.Database.create(str(path)) as db:
        db.kv_put(b"settings", b"theme", b"dark")
        db.kv_put(b"settings", b"retries", b"\x00\x01\x02")
        db.kv_put(b"settings", b"empty", b"")

        assert db.kv_get(b"settings", b"theme") == b"dark"
        assert db.kv_get(b"settings", b"retries") == b"\x00\x01\x02"
        assert db.kv_get(b"settings", b"empty") == b""
        assert db.kv_get(b"settings", b"ghost") is None
        assert db.kv_get(b"other", b"theme") is None

        assert db.kv_count(b"settings") == 3

        db.kv_put(b"settings", b"theme", b"light")
        assert db.kv_get(b"settings", b"theme") == b"light"
        assert db.kv_count(b"settings") == 3

        db.kv_delete(b"settings", b"theme")
        assert db.kv_get(b"settings", b"theme") is None
        assert db.kv_count(b"settings") == 2

        db.kv_delete(b"settings", b"ghost")
        assert db.kv_count(b"settings") == 2

        db.kv_clear_namespace(b"settings")
        assert db.kv_count(b"settings") == 0


def test_kv_get_many_preserves_order_and_duplicates(tmp_path):
    path = tmp_path / "kv-many.zova"
    with zova.Database.create(str(path)) as db:
        db.kv_put(b"ns", b"a", b"1")
        db.kv_put(b"ns", b"b", b"2")
        db.kv_put(b"ns", b"c", b"3")

        results = db.kv_get_many(b"ns", [b"c", b"ghost", b"a", b"c"])
        assert results == [b"3", None, b"1", b"3"]


def test_kv_put_many_and_delete_many(tmp_path):
    path = tmp_path / "kv-batch.zova"
    with zova.Database.create(str(path)) as db:
        db.kv_put_many(b"ns", [(b"k1", b"v1"), (b"k2", b"v2"), (b"k3", b"")])
        assert db.kv_count(b"ns") == 3

        db.kv_delete_many(b"ns", [b"k1", b"ghost", b"k3"])
        assert db.kv_count(b"ns") == 1
        assert db.kv_get(b"ns", b"k2") == b"v2"

        db.kv_put_many(b"ns", [])
        db.kv_delete_many(b"ns", [])
        assert db.kv_count(b"ns") == 1


def test_kv_partitions_by_namespace(tmp_path):
    path = tmp_path / "kv-partition.zova"
    with zova.Database.create(str(path)) as db:
        db.kv_put(b"a", b"key", b"1")
        db.kv_put(b"b", b"key", b"2")

        assert db.kv_get(b"a", b"key") == b"1"
        assert db.kv_get(b"b", b"key") == b"2"
        assert db.kv_count(b"a") == 1
        assert db.kv_count(b"b") == 1

        db.kv_clear_namespace(b"a")
        assert db.kv_count(b"a") == 0
        assert db.kv_count(b"b") == 1
