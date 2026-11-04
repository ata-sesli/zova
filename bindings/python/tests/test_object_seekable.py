import io

import pytest

import zova


def fixture_bytes(length: int) -> bytes:
    return bytes((index * 31 + index // 7) % 251 for index in range(length))


STREAMING = zova.ObjectPutOptions(zova.ObjectStorageProfile.STREAMING)


def test_seekable_reader_reads_sequentially_and_seeks(tmp_path):
    data = fixture_bytes((2 << 20) + 4321)
    with zova.Database.create(str(tmp_path / "seekable.zova")) as db:
        object_id = db.put_object_with_options(data, STREAMING)
        with db.object_seekable_reader(object_id) as reader:
            assert isinstance(reader, zova.ObjectSeekableReader)
            assert reader.size == len(data)
            assert reader.readable() and reader.seekable()

            chunks = []
            while chunk := reader.read(32 * 1024):
                chunks.append(chunk)
            assert b"".join(chunks) == data
            assert reader.tell() == len(data)

            assert reader.seek(0) == 0
            assert reader.read(5) == data[:5]

            middle = (1 << 20) - 3
            assert reader.seek(middle) == middle
            assert reader.read(6) == data[middle : middle + 6]
            assert reader.seek(-4, io.SEEK_CUR) == middle + 2

            buffer = bytearray(b"\xff" * 8)
            assert reader.readinto(buffer) == 8
            assert bytes(buffer) == data[middle + 2 : middle + 10]

            assert reader.seek(-10, io.SEEK_END) == len(data) - 10
            short = bytearray(b"\xee" * 16)
            assert reader.readinto(short) == 10
            assert bytes(short) == data[-10:] + b"\xee" * 6
            assert reader.read(1) == b""

            assert reader.seek(len(data) + 5) == len(data) + 5
            assert reader.read(4) == b""
            with pytest.raises(ValueError):
                reader.seek(-1)
            with pytest.raises(ValueError):
                reader.seek(0, 3)

            assert reader.seek(len(data) - 3) == len(data) - 3
            assert reader.read() == data[-3:]

        assert reader.closed
        reader.close()
        with pytest.raises(zova.ClosedHandleError):
            reader.read(1)


def test_seekable_reader_reports_an_object_deleted_while_reading(tmp_path):
    data = fixture_bytes((2 << 20) + 9)
    with zova.Database.create(str(tmp_path / "deleted.zova")) as db:
        object_id = db.put_object_with_options(data, STREAMING)
        reader = db.object_seekable_reader(object_id)
        assert reader.read(16) == data[:16]

        db.delete_object(object_id)
        # Bytes of the already verified chunk stay readable.
        assert reader.read(16) == data[16:32]
        reader.seek(1 << 20)
        with pytest.raises(zova.ZovaError) as error:
            reader.read(16)
        assert error.value.status_name == "ZOVA_OBJECT_NOT_FOUND"
        reader.close()


def test_seekable_reader_keeps_database_alive_after_close(tmp_path):
    data = b"owned seekable reader"
    db = zova.Database.create(str(tmp_path / "owned.zova"))
    object_id = db.put_object(data)
    reader = db.object_seekable_reader(object_id)
    db.close()
    reader.seek(6)
    assert reader.read() == data[6:]
    reader.close()

    with zova.Database.create(str(tmp_path / "missing.zova")) as db:
        with pytest.raises(zova.ZovaError):
            db.object_seekable_reader(zova.object_id(b"missing"))
