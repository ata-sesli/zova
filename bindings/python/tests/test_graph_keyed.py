import pytest

import zova

G = "code"
OUT = zova.GraphNeighborDirection.OUTGOING
IN = zova.GraphNeighborDirection.INCOMING


def node(node_id, kind="file"):
    return zova.GraphNodeInput(G, node_id, kind, zova.GraphTargetType.NONE)


def edge(from_node_id, edge_type, to_node_id):
    return zova.GraphEdgeInput(G, from_node_id, edge_type, to_node_id)


def fresh_node(node_id):
    return zova.GraphFreshNodeInput(node_id, "file", zova.GraphTargetType.NONE)


def test_batch_mutations_and_degree():
    with zova.Database.create_memory() as db:
        db.create_graph(G)
        db.put_graph_nodes([node("a"), node("b"), node("c")])
        db.put_graph_edges([edge("a", "imports", "b"), edge("a", "calls", "c")])
        assert db.graph_degree(G, "a", OUT) == 2
        assert db.graph_degree(G, "a", OUT, "calls") == 1
        assert db.graph_degree(G, "b", IN) == 1

        db.delete_graph_edges([edge("a", "calls", "c")])
        assert db.graph_degree(G, "a", OUT) == 1
        db.delete_graph_nodes(G, ["b", "c"])
        assert db.graph_info(G).node_count == 1
        assert db.graph_info(G).edge_count == 0

        # A failing batch changes nothing.
        with pytest.raises(zova.ZovaError):
            db.put_graph_edges([edge("a", "x", "a"), edge("a", "x", "missing")])
        assert db.graph_degree(G, "a", OUT) == 0


def test_keyed_crud_payloads_degrees_and_scan():
    with zova.Database.create_memory() as db:
        db.create_graph(G)
        node_keys = db.put_graph_nodes_keyed([node("a"), node("b", "dir")])
        assert len(node_keys) == 2
        edge_keys = db.put_graph_edges_keyed([edge("a", "imports", "b")])
        assert len(edge_keys) == 1

        nodes = db.get_graph_nodes_keyed(G, [node_keys[1], 999_999, node_keys[0]])
        assert nodes[0].node_id == "b" and nodes[0].kind == "dir"
        assert nodes[0].node_key == node_keys[1]
        assert nodes[1] is None
        assert nodes[2].node_id == "a"

        (found, missing) = db.get_graph_edges_keyed(G, [edge_keys[0], 999_999])
        assert missing is None
        assert (found.source_node_key, found.edge_type, found.target_node_key) == (
            node_keys[0],
            "imports",
            node_keys[1],
        )

        neighbors = db.graph_neighbors_keyed(zova.GraphNeighborsOptions(G, "a", OUT))
        assert [(n.edge_key, n.neighbor_node_key, n.node_id) for n in neighbors] == [
            (edge_keys[0], node_keys[1], "b")
        ]
        assert db.graph_degrees_keyed(G, node_keys, OUT) == [1, 0]
        assert db.graph_degrees_keyed(G, node_keys, IN, "imports") == [0, 1]

        assert db.get_graph_edge_payloads(G, [edge_keys[0], 999_999]) == [b"", None]
        db.replace_graph_edge_payloads(G, [(edge_keys[0], b"\x00payload")])
        assert db.get_graph_edge_payloads(G, edge_keys) == [b"\x00payload"]

        first = db.graph_scan(G, node_limit=1, edge_limit=5)
        assert [n.node_id for n in first.nodes] == ["a"]
        assert first.has_more_nodes
        assert len(first.edges) == 1 and not first.has_more_edges
        last = first.nodes[-1]
        second = db.graph_scan(
            G,
            node_limit=5,
            edge_limit=5,
            node_after=(last.created_order, last.node_key),
            edge_after=(first.edges[-1].created_order, first.edges[-1].edge_key),
        )
        assert [n.node_id for n in second.nodes] == ["b"]
        assert not second.has_more_nodes
        assert second.edges == []


def test_directional_walks():
    with zova.Database.create_memory() as db:
        db.create_graph(G)
        db.put_graph_nodes([node("a"), node("b"), node("c")])
        db.put_graph_edges([edge("a", "imports", "b"), edge("b", "imports", "c")])

        options = zova.GraphWalkDirectionOptions(G, "c", IN, max_depth=2, limit=10)
        items = db.graph_walk_direction(options)
        assert [(item.node_id, item.depth) for item in items] == [("c", 0), ("b", 1), ("a", 2)]

        items, profile = db.graph_walk_direction_profiled(
            zova.GraphWalkDirectionOptions(G, "a", OUT, "imports", 1, 10)
        )
        assert [item.node_id for item in items] == ["a", "b"]
        assert profile.result_count == 2
        assert profile.total_profiled_ms >= 0

        with pytest.raises(ValueError):
            zova.GraphWalkDirectionOptions(G, "a", 7)


def test_fresh_graph_builds():
    nodes = [fresh_node("a"), fresh_node("b")]
    with zova.Database.create_memory() as db:
        node_keys, edge_keys = db.build_fresh_graph_keyed(
            G,
            nodes,
            [
                zova.GraphFreshEdgeInput(0, "imports", 1),
                zova.GraphFreshEdgeInput(0, "imports", 1),
            ],
        )
        assert len(node_keys) == 2
        # The normalizing builder deduplicates edges; both inputs map to one key.
        assert len(edge_keys) == 2 and edge_keys[0] == edge_keys[1]
        assert db.graph_info(G).edge_count == 1

    with zova.Database.create_memory() as db:
        with pytest.raises(ValueError):
            db.build_fresh_graph_prepared_keyed(
                G, nodes, [zova.GraphFreshEdgeInput(0, "imports", 1, b"x")]
            )
        node_keys, edge_keys = db.build_fresh_graph_prepared_keyed(
            G, nodes, [zova.GraphFreshEdgeInput(0, "imports", 1)]
        )
        assert db.get_graph_edges_keyed(G, edge_keys)[0].target_node_key == node_keys[1]

    with zova.Database.create_memory() as db:
        _, edge_keys = db.build_fresh_graph_prepared_keyed_with_payloads(
            G,
            nodes,
            [zova.GraphFreshEdgeInput(0, "imports", 1, b"weight=1")],
        )
        assert db.get_graph_edge_payloads(G, edge_keys) == [b"weight=1"]


def test_delete_vectors_and_multi_i8_search():
    with zova.Database.create_memory() as db:
        db.create_vector_collection(
            "codes", zova.VectorCollectionOptions(2, zova.VectorMetric.COSINE, zova.VectorElementType.I8)
        )
        db.put_vectors(
            "codes",
            [
                zova.VectorInput("east", zova.VectorElementType.I8, [100, 0]),
                zova.VectorInput("north", zova.VectorElementType.I8, [0, 100]),
                zova.VectorInput("diag", zova.VectorElementType.I8, [70, 70]),
                zova.VectorInput("gone", zova.VectorElementType.I8, [1, 1]),
            ],
        )
        db.delete_vectors("codes", ["gone", "never-existed"])
        assert not db.has_vector("codes", "gone")

        # Each vector scores by its least similar query row, so the diagonal
        # vector beats both axis vectors for the two axis queries.
        results = db.search_vectors_multi_i8("codes", [100, 0, 0, 100], 2, 2, limit=3)
        assert results[0].id == "diag"
        assert {result.id for result in results} == {"diag", "east", "north"}

        within = db.search_vectors_multi_i8(
            "codes", [100, 0, 0, 100], 2, 2, limit=3, candidate_ids=["east", "north"]
        )
        assert {result.id for result in within} == {"east", "north"}

        prefiltered = db.search_vectors_multi_i8(
            "codes",
            [100, 0, 0, 100],
            2,
            2,
            limit=1,
            mode=zova.VectorMultiI8SearchMode.CBM_PREFILTER_MIN_COSINE,
            aggregation=zova.VectorMultiI8Aggregation.MIN_COSINE,
            prefilter_query_index=0,
            prefilter_limit=2,
        )
        assert len(prefiltered) == 1

        with pytest.raises(ValueError):
            db.search_vectors_multi_i8("codes", [1, 1], 1, 2, limit=1, mode=9)
