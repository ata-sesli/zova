from pathlib import Path
from tempfile import TemporaryDirectory

import zova


def main() -> None:
    with TemporaryDirectory() as tmp:
        path = Path(tmp) / "graphs.zova"

        with zova.Database.create(str(path)) as db:
            db.exec("create table messages(id text primary key, body text not null)")
            db.exec("insert into messages(id, body) values ('m1', 'hello'), ('m2', 'reply')")
            db.create_graph(zova.DEFAULT_GRAPH_NAME)

            for message_id in ["m1", "m2"]:
                db.put_graph_node(
                    zova.GraphNodeInput(
                        zova.DEFAULT_GRAPH_NAME,
                        message_id,
                        "message",
                        zova.GraphTargetType.RECORD,
                        "messages",
                        message_id,
                    )
                )

            db.put_graph_edge(zova.GraphEdgeInput(zova.DEFAULT_GRAPH_NAME, "m2", "replies_to", "m1"))

            neighbors = db.graph_neighbors(
                zova.GraphNeighborsOptions(
                    zova.DEFAULT_GRAPH_NAME,
                    "m2",
                    zova.GraphNeighborDirection.OUTGOING,
                    "replies_to",
                    10,
                )
            )
            for neighbor in neighbors:
                with db.prepare("select body from messages where id = ?1") as stmt:
                    stmt.bind_text(1, neighbor.node_id)
                    if stmt.step() == zova.Step.ROW:
                        print(neighbor.edge_type, stmt.column_text(0))


if __name__ == "__main__":
    main()
