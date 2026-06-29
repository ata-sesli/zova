from pathlib import Path
from tempfile import TemporaryDirectory

import zova


with TemporaryDirectory() as tmp:
    path = Path(tmp) / "notifications.zova"

    with zova.Database.create(str(path)) as db:
        db.exec(
            "create table attachments("
            "id integer primary key, "
            "filename text not null, "
            "object_id blob not null)"
        )

        with db.listen("message:1:attachments") as listener:
            object_id = db.put_object(b"hello from a Python notification")

            db.begin_immediate()
            with db.prepare("insert into attachments(filename, object_id) values (?1, ?2)") as stmt:
                stmt.bind_text(1, "hello.txt")
                stmt.bind_blob(2, bytes(object_id))
                assert stmt.step() == zova.Step.DONE
            db.notify("message:1:attachments", "changed")
            assert listener.try_receive() is None
            db.commit()

            note = listener.try_receive()
            print(note.channel, note.payload)

        db.exec("create table chunks(id text primary key, vector_id text not null)")
        db.create_vector_collection("chunks", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
        db.put_vector("chunks", "chunk:1", [0.0, 0.0])

        with db.listen("vectors:chunks") as vector_listener:
            db.begin_immediate()
            db.exec("insert into chunks(id, vector_id) values ('c1', 'chunk:1')")
            db.notify("vectors:chunks", "changed")
            db.commit()

            vector_note = vector_listener.try_receive()
            results = db.search_vectors("chunks", [0.0, 0.0], 1)
            print(vector_note.channel, results[0].id)
