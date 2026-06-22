from pathlib import Path
from tempfile import TemporaryDirectory

import zova


with TemporaryDirectory() as tmp:
    path = Path(tmp) / "attachments.zova"

    with zova.Database.create(str(path)) as db:
        db.exec(
            "create table attachments("
            "id integer primary key, "
            "filename text not null, "
            "object_id blob not null)"
        )

        with db.object_writer() as writer:
            writer.write(b"hello ")
            writer.write(b"from a streamed object")
            object_id = writer.finish()

        with db.prepare("insert into attachments(filename, object_id) values (?1, ?2)") as stmt:
            stmt.bind_text(1, "greeting.txt")
            stmt.bind_blob(2, bytes(object_id))
            assert stmt.step() == zova.Step.DONE

        preview = db.read_object_range(object_id, 0, 11)
        print(preview.decode("utf-8"))

        manifest = db.object_manifest(object_id)
        for chunk in manifest.chunks:
            chunk_bytes = db.get_object_chunk(chunk.hash)
            assert len(chunk_bytes) == chunk.size_bytes

    with zova.Database.open(str(path)) as db:
        with db.prepare("select filename, object_id from attachments where id = 1") as stmt:
            assert stmt.step() == zova.Step.ROW
            filename = stmt.column_text(0)
            object_id = zova.ObjectId(stmt.column_blob(1))

        print(filename, db.get_object(object_id).decode("utf-8"))
