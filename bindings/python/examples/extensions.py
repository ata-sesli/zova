from pathlib import Path
from tempfile import TemporaryDirectory

import zova


def exec_one(db: zova.Database, sql: str) -> None:
    with db.prepare(sql) as stmt:
        assert stmt.step() == zova.Step.ROW


def trgm_put(
    db: zova.Database,
    index: str,
    document_id: str,
    target_type: str,
    target_namespace: str | None,
    target_ref: str | None,
    text: str,
) -> None:
    with db.prepare("select zova_trgm_put(?1, ?2, ?3, ?4, ?5, ?6)") as stmt:
        stmt.bind_text(1, index)
        stmt.bind_text(2, document_id)
        stmt.bind_text(3, target_type)
        if target_namespace is None:
            stmt.bind_null(4)
        else:
            stmt.bind_text(4, target_namespace)
        if target_ref is None:
            stmt.bind_null(5)
        else:
            stmt.bind_text(5, target_ref)
        stmt.bind_text(6, text)
        assert stmt.step() == zova.Step.ROW


def main() -> None:
    with TemporaryDirectory() as tmp:
        path = Path(tmp) / "extensions.zova"

        with zova.Database.create(str(path)) as db:
            db.install_extension("trgm")
            db.check_extensions()
            exec_one(db, "select zova_trgm_create_index('targets')")

            db.exec("create table messages(id text primary key, graph_node_id text not null, body text not null)")
            db.exec(
                "insert into messages(id, graph_node_id, body) "
                "values ('m1', 'message:m1', 'Receipt attachment failed to upload')"
            )

            object_id = db.put_object(b"receipt attachment bytes")
            object_hex = object_id.hex()
            db.create_vector_collection("chunks", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
            db.put_vector("chunks", "chunk:m1", [0.0, 1.0])
            db.create_graph(zova.DEFAULT_GRAPH_NAME)
            db.put_graph_node(
                zova.GraphNodeInput(
                    zova.DEFAULT_GRAPH_NAME,
                    "message:m1",
                    "message",
                    zova.GraphTargetType.RECORD,
                    "messages",
                    "m1",
                )
            )
            db.put_graph_node(
                zova.GraphNodeInput(
                    zova.DEFAULT_GRAPH_NAME,
                    "entity:receipt",
                    "entity",
                    zova.GraphTargetType.ENTITY,
                    None,
                    "receipt",
                )
            )
            db.put_graph_edge(zova.GraphEdgeInput(zova.DEFAULT_GRAPH_NAME, "message:m1", "mentions", "entity:receipt"))

            with db.listen("search:indexed") as listener:
                db.begin_immediate()
                trgm_put(db, "targets", "message:m1", "record", "messages", "m1", "Receipt attachment failed to upload")
                trgm_put(db, "targets", "attachment:m1", "object", None, object_hex, "receipt.pdf")
                trgm_put(db, "targets", "chunk:m1", "vector", "chunks", "chunk:m1", "receipt upload chunk")
                trgm_put(db, "targets", "entity:receipt", "graph", zova.DEFAULT_GRAPH_NAME, "entity:receipt", "receipt")
                db.notify("search:indexed", "targets")
                assert listener.try_receive() is None
                db.commit()
                note = listener.try_receive()
                print(note.channel, note.payload)

            with db.prepare(
                """
                select document_id, target_type, target_namespace, target_ref
                from zova_trgm_search
                where index_name = 'targets'
                  and query = ?1
                  and "limit" = 4
                order by rank
                """
            ) as stmt:
                stmt.bind_text(1, "reciept attachement")
                while stmt.step() == zova.Step.ROW:
                    print(stmt.column_text(0), stmt.column_text(1), stmt.column_text(2), stmt.column_text(3))


if __name__ == "__main__":
    main()
