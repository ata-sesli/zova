import zova


def main() -> None:
    with zova.Database.create("python-vectors.zova") as db:
        db.exec(
            "create table chunks("
            "id text primary key, "
            "document_id text not null, "
            "text text not null, "
            "vector_id text not null)"
        )

        db.create_vector_collection(
            "chunks",
            zova.VectorCollectionOptions(2, zova.VectorMetric.L2),
        )
        db.put_vectors(
            "chunks",
            [
                zova.VectorInput("chunk:1", [0.0, 0.0]),
                zova.VectorInput("chunk:2", [1.0, 0.0]),
                zova.VectorInput("chunk:3", [5.0, 0.0]),
            ],
        )

        rows = [
            ("c1", "doc-a", "first chunk", "chunk:1"),
            ("c2", "doc-a", "near chunk", "chunk:2"),
            ("c3", "doc-b", "other document", "chunk:3"),
        ]
        with db.prepare("insert into chunks(id, document_id, text, vector_id) values (?1, ?2, ?3, ?4)") as insert:
            for row in rows:
                insert.bind_text(1, row[0])
                insert.bind_text(2, row[1])
                insert.bind_text(3, row[2])
                insert.bind_text(4, row[3])
                insert.step()
                insert.reset()

        for result in db.search_vectors_in("chunks", [0.0, 0.0], ["chunk:1", "chunk:2"], 2):
            with db.prepare("select text from chunks where vector_id = ?1") as lookup:
                lookup.bind_text(1, result.id)
                lookup.step()
                print(result.id, result.distance, lookup.column_text(0))

        query_blob = zova.encode_f32_le([0.0, 0.0])
        with db.prepare(
            "select c.id, zova_vector_distance('chunks', c.vector_id, ?1) as distance "
            "from chunks as c "
            "where c.document_id = 'doc-a' "
            "order by distance "
            "limit 2"
        ) as sql_distance:
            sql_distance.bind_blob(1, query_blob)
            while sql_distance.step() == zova.Step.ROW:
                print("distance", sql_distance.column_text(0), sql_distance.column_float(1))

        with db.prepare("select zova_vector_distance_by_id('chunks', 'chunk:2', 'chunk:1')") as by_id:
            by_id.step()
            print("row-to-row distance", by_id.column_float(0))

        with db.prepare(
            "select c.text, s.distance "
            "from zova_vector_search as s "
            "join chunks as c on c.vector_id = s.vector_id "
            "where s.collection = 'chunks' "
            "and s.query_vector = ?1 "
            "and s.top_k = 2 "
            "order by s.rank"
        ) as vector_search:
            vector_search.bind_blob(1, query_blob)
            while vector_search.step() == zova.Step.ROW:
                print("search", vector_search.column_text(0), vector_search.column_float(1))


if __name__ == "__main__":
    main()
