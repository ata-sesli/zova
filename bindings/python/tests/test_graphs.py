import pytest

import zova


def node(
    node_id,
    kind="message",
    target_type=zova.GraphTargetType.NONE,
    target_namespace=None,
    target_ref=None,
):
    return zova.GraphNodeInput(
        zova.DEFAULT_GRAPH_NAME,
        node_id,
        kind,
        target_type,
        target_namespace,
        target_ref,
    )


def edge(from_node_id, edge_type, to_node_id):
    return zova.GraphEdgeInput(zova.DEFAULT_GRAPH_NAME, from_node_id, edge_type, to_node_id)


def test_graph_lifecycle_nodes_edges_neighbors_and_walk(tmp_path):
    path = tmp_path / "graphs.zova"

    with zova.Database.create(str(path)) as db:
        db.create_graph(zova.DEFAULT_GRAPH_NAME)
        db.create_graph("knowledge")
        assert db.has_graph(zova.DEFAULT_GRAPH_NAME)

        info = db.graph_info(zova.DEFAULT_GRAPH_NAME)
        assert info.name == zova.DEFAULT_GRAPH_NAME
        assert info.node_count == 0
        assert info.edge_count == 0
        with pytest.raises(AttributeError):
            info.name = "changed"

        assert [item.name for item in db.list_graphs()] == [zova.DEFAULT_GRAPH_NAME, "knowledge"]

        targets = [
            node("record:1", "record", zova.GraphTargetType.RECORD, "messages", "1"),
            node("object:1", "attachment", zova.GraphTargetType.OBJECT, None, "00" * 32),
            node("chunk:1", "chunk", zova.GraphTargetType.OBJECT_CHUNK, None, "11" * 32),
            node("vector:1", "embedding", zova.GraphTargetType.VECTOR, "messages", "vec-1"),
            node("entity:alice", "person", zova.GraphTargetType.ENTITY, None, "alice"),
            node("fact:1", "fact", zova.GraphTargetType.FACT, None, "fact-1"),
            node("concept:1", "concept", zova.GraphTargetType.CONCEPT, None, "concept-1"),
            node("external:1", "url", zova.GraphTargetType.EXTERNAL, None, "https://example.com"),
            node("none:1", "scratch", zova.GraphTargetType.NONE),
        ]
        for item in targets:
            db.put_graph_node(item)

        db.put_graph_node(node("record:1", "message", zova.GraphTargetType.RECORD, "messages", "1"))
        got = db.get_graph_node(zova.DEFAULT_GRAPH_NAME, "record:1")
        assert got.node_id == "record:1"
        assert got.kind == "message"
        assert got.target_type == zova.GraphTargetType.RECORD
        assert got.target_namespace == "messages"
        assert got.target_ref == "1"
        assert db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "record:1")

        db.put_graph_edge(edge("record:1", "has_attachment", "object:1"))
        db.put_graph_edge(edge("object:1", "has_chunk", "chunk:1"))
        db.put_graph_edge(edge("record:1", "mentions", "entity:alice"))
        db.put_graph_edge(edge("entity:alice", "supports", "fact:1"))
        db.put_graph_edge(edge("fact:1", "related", "concept:1"))
        db.put_graph_edge(edge("record:1", "embedded_as", "vector:1"))
        db.put_graph_edge(edge("record:1", "has_attachment", "object:1"))

        got_edge = db.get_graph_edge(zova.DEFAULT_GRAPH_NAME, "record:1", "has_attachment", "object:1")
        assert got_edge.from_node_id == "record:1"
        assert got_edge.edge_type == "has_attachment"
        assert got_edge.to_node_id == "object:1"
        assert db.has_graph_edge(zova.DEFAULT_GRAPH_NAME, "record:1", "has_attachment", "object:1")

        outgoing = db.graph_neighbors(
            zova.GraphNeighborsOptions(
                zova.DEFAULT_GRAPH_NAME,
                "record:1",
                zova.GraphNeighborDirection.OUTGOING,
                None,
                10,
            )
        )
        assert sorted((item.node_id, item.edge_type) for item in outgoing) == [
            ("entity:alice", "mentions"),
            ("object:1", "has_attachment"),
            ("vector:1", "embedded_as"),
        ]

        incoming = db.graph_neighbors(
            zova.GraphNeighborsOptions(
                zova.DEFAULT_GRAPH_NAME,
                "object:1",
                zova.GraphNeighborDirection.INCOMING,
                "has_attachment",
                10,
            )
        )
        assert [(item.node_id, item.edge_type) for item in incoming] == [("record:1", "has_attachment")]
        assert (
            db.graph_neighbors(
                zova.GraphNeighborsOptions(
                    zova.DEFAULT_GRAPH_NAME,
                    "record:1",
                    zova.GraphNeighborDirection.OUTGOING,
                    None,
                    0,
                )
            )
            == []
        )

        walk = db.graph_walk(zova.GraphWalkOptions(zova.DEFAULT_GRAPH_NAME, "record:1", None, 3, 10))
        walk_by_id = {item.node_id: item for item in walk}
        assert walk_by_id["record:1"].depth == 0
        assert walk_by_id["object:1"].predecessor_node_id == "record:1"
        assert walk_by_id["object:1"].edge_type == "has_attachment"
        assert walk_by_id["entity:alice"].predecessor_node_id == "record:1"
        assert walk_by_id["entity:alice"].edge_type == "mentions"
        assert walk_by_id["chunk:1"].depth == 2
        assert walk_by_id["concept:1"].depth == 3

        assert [item.node_id for item in db.graph_walk(zova.GraphWalkOptions(zova.DEFAULT_GRAPH_NAME, "record:1", "mentions", 2, 10))] == [
            "record:1",
            "entity:alice",
        ]

        db.delete_graph_edge(edge("record:1", "embedded_as", "vector:1"))
        assert not db.has_graph_edge(zova.DEFAULT_GRAPH_NAME, "record:1", "embedded_as", "vector:1")
        db.delete_graph_node(zova.DEFAULT_GRAPH_NAME, "object:1")
        assert not db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "object:1")
        assert not db.has_graph_edge(zova.DEFAULT_GRAPH_NAME, "record:1", "has_attachment", "object:1")

        with pytest.raises(zova.ZovaError) as exc:
            db.put_graph_edge(edge("missing", "mentions", "entity:alice"))
        assert exc.value.status_name == "ZOVA_GRAPH_NODE_NOT_FOUND"

        db.delete_graph("knowledge")
        assert not db.has_graph("knowledge")


def test_sql_native_graph_helpers_join_app_rows(tmp_path):
    path = tmp_path / "graph_sql.zova"

    with zova.Database.create(str(path)) as db:
        db.exec(
            "create table messages(graph_node_id text primary key, body text);"
            "insert into messages(graph_node_id, body) values "
            "('message:1', 'root'), "
            "('message:2', 'reply'), "
            "('message:3', 'mentioned')"
        )
        db.create_graph(zova.DEFAULT_GRAPH_NAME)
        for node_id in ["message:1", "message:2", "message:3"]:
            db.put_graph_node(node(node_id, "message", zova.GraphTargetType.RECORD, "messages", node_id))
        db.put_graph_edge(edge("message:1", "replies_to", "message:2"))
        db.put_graph_edge(edge("message:2", "mentions", "message:3"))

        with db.prepare(
            "select m.body, g.edge_type "
            "from zova_graph_neighbors as g "
            "join messages as m on m.graph_node_id = g.node_id "
            "where g.graph_name = 'default' "
            "and g.source_node_id = 'message:1' "
            'and g."limit" = 10 '
            "order by g.rank"
        ) as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "reply"
            assert stmt.column_text(1) == "replies_to"
            assert stmt.step() == zova.Step.DONE

        with db.prepare(
            "select node_id, depth, predecessor_node_id, edge_type "
            "from zova_graph_walk "
            "where graph_name = 'default' "
            "and start_node_id = 'message:1' "
            "and max_depth = 2 "
            'and "limit" = 10 '
            "order by rank"
        ) as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "message:1"
            assert stmt.column_int(1) == 0
            assert stmt.column_text(2) is None
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "message:2"
            assert stmt.column_int(1) == 1
            assert stmt.column_text(2) == "message:1"
            assert stmt.column_text(3) == "replies_to"
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "message:3"


def test_graph_transactions_savepoints_read_only_and_errors(tmp_path):
    path = tmp_path / "graph_tx.zova"

    with zova.Database.create(str(path)) as db:
        db.create_graph(zova.DEFAULT_GRAPH_NAME)
        db.put_graph_node(node("root"))

        db.begin()
        db.put_graph_node(node("rolled-back"))
        db.rollback()
        assert not db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "rolled-back")

        db.begin()
        db.put_graph_node(node("kept"))
        db.savepoint("inner")
        db.put_graph_node(node("discarded"))
        db.rollback_to_savepoint("inner")
        db.release_savepoint("inner")
        db.commit()
        assert db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "kept")
        assert not db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "discarded")

        with pytest.raises(zova.ZovaError) as exc:
            db.create_graph("_zova_bad")
        assert exc.value.status_name == "ZOVA_GRAPH_INVALID"

        with pytest.raises(TypeError):
            db.put_graph_node("not a graph input")

    with zova.Database.open(str(path), read_only=True) as db:
        assert db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "root")
        with pytest.raises(zova.ZovaError) as exc:
            db.put_graph_node(node("blocked"))
        assert exc.value.status_name == "ZOVA_READ_ONLY"


def test_graph_vector_target_diagnostic_after_vector_delete(tmp_path):
    path = tmp_path / "graph_diag.zova"

    with zova.Database.create(str(path)) as db:
        db.create_vector_collection("messages", zova.VectorCollectionOptions(2, zova.VectorMetric.L2))
        db.put_vector("messages", "vec-1", [1.0, 0.0])
        db.create_graph(zova.DEFAULT_GRAPH_NAME)
        db.put_graph_node(node("msg:1", "message", zova.GraphTargetType.VECTOR, "messages", "vec-1"))
        db.delete_vector("messages", "vec-1")
        got = db.get_graph_node(zova.DEFAULT_GRAPH_NAME, "msg:1")
        assert got.target_type == zova.GraphTargetType.VECTOR
        assert got.target_namespace == "messages"
        assert got.target_ref == "vec-1"

    with zova.Database.open(str(path)) as db:
        assert db.has_graph_node(zova.DEFAULT_GRAPH_NAME, "msg:1")
