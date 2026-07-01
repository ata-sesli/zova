from pathlib import Path
from tempfile import TemporaryDirectory

import zova


def main() -> None:
    with TemporaryDirectory() as tmp:
        path = Path(tmp) / "graph-rag.zova"

        with zova.Database.create(str(path)) as db:
            db.exec("create table chunks(id text primary key, body text not null)")
            db.exec(
                "insert into chunks(id, body) values "
                "('chunk:1', 'Zova stores records, objects, vectors, and graphs together')"
            )
            db.create_graph(zova.DEFAULT_GRAPH_NAME)
            db.create_vector_collection("chunks", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
            db.put_vector("chunks", "chunk:1", [0.0, 1.0])

            object_id = db.put_object(b"attachment bytes")
            object_hex = object_id.hex()

            db.put_graph_node(
                zova.GraphNodeInput(
                    zova.DEFAULT_GRAPH_NAME,
                    "chunk:1",
                    "chunk",
                    zova.GraphTargetType.VECTOR,
                    "chunks",
                    "chunk:1",
                )
            )
            db.put_graph_node(
                zova.GraphNodeInput(
                    zova.DEFAULT_GRAPH_NAME,
                    "attachment:1",
                    "attachment",
                    zova.GraphTargetType.OBJECT,
                    "sha256",
                    object_hex,
                )
            )
            db.put_graph_node(
                zova.GraphNodeInput(
                    zova.DEFAULT_GRAPH_NAME,
                    "entity:zova",
                    "entity",
                    zova.GraphTargetType.ENTITY,
                    None,
                    "zova",
                )
            )
            db.put_graph_edge(zova.GraphEdgeInput(zova.DEFAULT_GRAPH_NAME, "chunk:1", "mentions", "entity:zova"))
            db.put_graph_edge(
                zova.GraphEdgeInput(zova.DEFAULT_GRAPH_NAME, "chunk:1", "has_attachment", "attachment:1")
            )

            for hit in db.search_vectors("chunks", [0.0, 1.0], 1):
                neighbors = db.graph_neighbors(
                    zova.GraphNeighborsOptions(
                        zova.DEFAULT_GRAPH_NAME,
                        hit.id,
                        zova.GraphNeighborDirection.OUTGOING,
                        None,
                        10,
                    )
                )
                for neighbor in neighbors:
                    if neighbor.node_id == "attachment:1":
                        print("attachment bytes", len(db.get_object(object_id)))
                        continue

                    with db.prepare("select body from chunks where id = ?1") as stmt:
                        stmt.bind_text(1, hit.id)
                        if stmt.step() == zova.Step.ROW:
                            print(neighbor.node_id, stmt.column_text(0))


if __name__ == "__main__":
    main()
