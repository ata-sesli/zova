import pytest

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


def test_kv_scan_pages_in_key_byte_order(tmp_path):
    db = zova.Database.create(str(tmp_path / "scan.zova"))
    for key in [b"b", b"", b"a\xff", b"a", b"ab", b"a\x00", b"c"]:
        db.kv_put(b"ns", key, key)
    db.kv_put(b"other", b"a", b"elsewhere")

    entries, has_more = db.kv_scan(b"ns", limit=100)
    assert [key for key, _ in entries] == [b"", b"a", b"a\x00", b"ab", b"a\xff", b"b", b"c"]
    assert all(key == value for key, value in entries)
    assert has_more is False

    entries, has_more = db.kv_scan(b"ns", prefix=b"a", limit=2, keys_only=True)
    assert entries == [(b"a", b""), (b"a\x00", b"")]
    assert has_more is True
    entries, has_more = db.kv_scan(b"ns", prefix=b"a", after=entries[-1][0], limit=2)
    assert entries == [(b"ab", b"ab"), (b"a\xff", b"a\xff")]
    assert has_more is False

    entries, _ = db.kv_scan(b"ns", start=b"a\x00", end=b"b", limit=10)
    assert len(entries) == 3
    with pytest.raises(zova.ZovaError):
        db.kv_scan(b"ns", limit=0)
    db.close()


def test_kv_conditional_writes_report_whether_they_applied(tmp_path):
    db = zova.Database.create(str(tmp_path / "cas.zova"))
    assert db.kv_put_if_absent(b"ns", b"k", b"v1") is True
    assert db.kv_put_if_absent(b"ns", b"k", b"other") is False
    assert db.kv_compare_and_put(b"ns", b"k", b"stale", b"v2") is False
    assert db.kv_compare_and_put(b"ns", b"k", b"v1", b"v2") is True
    assert db.kv_compare_and_delete(b"ns", b"k", b"v1") is False
    assert db.kv_compare_and_delete(b"ns", b"k", b"v2") is True
    assert db.kv_get(b"ns", b"k") is None
    db.close()
