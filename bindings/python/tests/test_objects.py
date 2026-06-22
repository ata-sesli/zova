import hashlib
import sqlite3

import pytest

import zova


def fixture_bytes(length: int) -> bytes:
    return bytes((index * 31 + index // 7) % 251 for index in range(length))


def test_object_id_helpers_and_value_types():
    empty = zova.object_id(b"")
    assert isinstance(empty, zova.ObjectId)
    assert bytes(empty) == hashlib.sha256(b"").digest()
    assert empty.bytes == hashlib.sha256(b"").digest()
    assert empty.hex() == hashlib.sha256(b"").hexdigest()
    assert repr(empty).startswith("ObjectId(")
    assert empty == zova.ObjectId(bytes(empty))
    assert hash(empty) == hash(zova.ObjectId(bytes(empty)))

    chunk = zova.object_chunk_id(memoryview(b"abc"))
    assert isinstance(chunk, zova.ObjectChunkId)
    assert bytes(chunk) == hashlib.sha256(b"abc").digest()
    assert chunk.bytes == hashlib.sha256(b"abc").digest()
    assert chunk.hex() == hashlib.sha256(b"abc").hexdigest()
    assert repr(chunk).startswith("ObjectChunkId(")
    assert chunk == zova.ObjectChunkId(bytes(chunk))
    assert hash(chunk) == hash(zova.ObjectChunkId(bytes(chunk)))

    with pytest.raises(ValueError):
        zova.ObjectId(b"short")
    with pytest.raises(ValueError):
        zova.ObjectChunkId(b"short")


def test_put_get_range_manifest_chunks_and_delete(tmp_path):
    path = tmp_path / "objects.zova"
    cases = [
        b"",
        b"hello object",
        b"binary\0with\0nul",
        fixture_bytes(140_000),
    ]

    with zova.Database.create(str(path)) as db:
        for data in cases:
            object_id = db.put_object(bytearray(data))
            assert object_id == zova.object_id(data)
            assert db.has_object(object_id)
            assert db.object_size(object_id) == len(data)
            assert db.get_object(object_id) == data
            assert db.read_object_range(object_id, 0, len(data)) == data
            assert db.read_object_range(object_id, len(data), 16) == b""
            assert db.read_object_range(object_id, 0, 0) == b""
            if data:
                start = min(7, len(data))
                assert db.read_object_range(object_id, start, 41) == data[start : start + 41]

            manifest = db.object_manifest(object_id)
            assert isinstance(manifest, zova.ObjectManifest)
            assert manifest.object_id == object_id
            assert manifest.size_bytes == len(data)
            assert manifest.chunk_count == len(manifest.chunks)
            assert manifest.chunker == "fastcdc-v1"
            assert db.object_chunk_count(object_id) == manifest.chunk_count
            for chunk in manifest.chunks:
                assert isinstance(chunk, zova.ObjectManifestChunk)
                chunk_bytes = db.get_object_chunk(chunk.hash)
                assert len(chunk_bytes) == chunk.size_bytes
                assert db.has_object_chunk(chunk.hash)

            db.delete_object(object_id)
            assert not db.has_object(object_id)
            with pytest.raises(zova.ZovaError) as exc:
                db.get_object(object_id)
            assert exc.value.status_name == "ZOVA_OBJECT_NOT_FOUND"


def test_loose_chunks_assembly_and_records_in_one_file(tmp_path):
    path = tmp_path / "assembly.zova"
    data = fixture_bytes(96_000)

    with zova.Database.create(str(path)) as db:
        db.exec("create table attachments(id integer primary key, object_id blob not null)")
        source_id = db.put_object(data)
        manifest = db.object_manifest(source_id)
        original_chunks = list(manifest.chunks)
        for chunk in original_chunks:
            start = chunk.offset
            end = start + chunk.size_bytes
            db.put_object_chunk(chunk.hash, data[start:end])

        db.delete_object(source_id)
        with pytest.raises(zova.ZovaError) as exc:
            db.assemble_object_from_chunks(source_id, len(data), original_chunks)
        assert exc.value.status_name == "ZOVA_OBJECT_CHUNK_NOT_FOUND"

        for chunk in original_chunks:
            start = chunk.offset
            end = start + chunk.size_bytes
            db.put_object_chunk(chunk.hash, data[start:end])

        db.assemble_object_from_chunks(source_id, len(data), list(reversed(original_chunks)))
        assert db.get_object(source_id) == data

        first_hash = original_chunks[0].hash
        assert db.delete_object_chunk(first_hash) is False
        db.delete_object(source_id)
        assert db.has_object_chunk(first_hash) is False

        loose_data = b"loose chunk"
        loose_hash = zova.object_chunk_id(loose_data)
        db.put_object_chunk(loose_hash, loose_data)
        assert db.delete_object_chunk(loose_hash) is True

        stored_id = db.put_object(b"stored through Python")
        with db.prepare("insert into attachments(object_id) values (?1)") as insert:
            insert.bind_blob(1, bytes(stored_id))
            assert insert.step() == zova.Step.DONE
        with db.prepare("select object_id from attachments where id = 1") as select:
            assert select.step() == zova.Step.ROW
            reloaded_id = zova.ObjectId(select.column_blob(0))
        assert db.get_object(reloaded_id) == b"stored through Python"


def test_object_writer_finish_cancel_close_context_and_errors(tmp_path):
    path = tmp_path / "writer.zova"
    data = fixture_bytes(180_000)

    with zova.Database.create(str(path)) as db:
        writer = db.object_writer()
        for chunk in [data[index : index + 333] for index in range(0, len(data), 333)]:
            writer.write(memoryview(chunk))
        object_id = writer.finish()
        assert object_id == zova.object_id(data)
        assert db.get_object(object_id) == data
        with pytest.raises(zova.ClosedHandleError):
            writer.write(b"after finish")

        cancel_id = zova.object_id(b"temporary")
        cancel_writer = db.object_writer()
        cancel_writer.write(b"temporary")
        cancel_writer.cancel()
        assert not db.has_object(cancel_id)
        with pytest.raises(zova.ClosedHandleError):
            cancel_writer.finish()

        context_id = zova.object_id(b"context cleanup")
        with db.object_writer() as context_writer:
            context_writer.write(b"context cleanup")
        assert not db.has_object(context_id)
        with pytest.raises(zova.ClosedHandleError):
            context_writer.write(b"after context")

        with db.object_writer() as finishing_writer:
            finishing_writer.write(b"context finish")
            finished_id = finishing_writer.finish()
        assert db.get_object(finished_id) == b"context finish"

        close_id = zova.object_id(b"close cleanup")
        close_writer = db.object_writer()
        close_writer.write(b"close cleanup")
        close_writer.close()
        assert not db.has_object(close_id)
        with pytest.raises(zova.ClosedHandleError):
            close_writer.cancel()


def test_objects_work_after_sqlite_conversion(tmp_path):
    source = tmp_path / "source.db"
    destination = tmp_path / "converted.zova"
    sql = sqlite3.connect(source)
    sql.execute("create table rows(id integer primary key, value text)")
    sql.execute("insert into rows(value) values ('before conversion')")
    sql.commit()
    sql.close()

    zova.convert_sqlite_to_zova(str(source), str(destination))
    with zova.Database.open(str(destination)) as db:
        object_id = db.put_object(b"after conversion")
        assert db.get_object(object_id) == b"after conversion"
        db.delete_object(object_id)
        assert not db.has_object(object_id)
        with db.prepare("select count(*) from rows") as rows:
            assert rows.step() == zova.Step.ROW
            assert rows.column_int(0) == 1


def test_object_methods_reject_wrong_id_types(tmp_path):
    path = tmp_path / "bad-types.zova"
    with zova.Database.create(str(path)) as db:
        with pytest.raises(TypeError):
            db.get_object(b"not an ObjectId")
        with pytest.raises(TypeError):
            db.get_object_chunk(b"not an ObjectChunkId")
        with pytest.raises(TypeError):
            db.assemble_object_from_chunks(zova.object_id(b""), 0, [object()])
