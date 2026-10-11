"""Run against an installed wheel, not the Python source directory."""
import os
from zova import Database, Step

db = Database.open(os.environ["ZOVA_PAGERANK_DATABASE"], read_only=True,
    extension_bundles=[os.environ["ZOVA_PAGERANK_BUNDLE"]],
    trust_store_path=os.environ["ZOVA_PAGERANK_TRUST"])
statement = db.prepare("SELECT node_key,node_id,score FROM zova_networkit_pagerank('cycle',0.85,1e-10,200,10,10)")
try:
    rows = []
    while statement.step() == Step.ROW:
        rows.append((statement.column_int(0), statement.column_text(1), statement.column_float(2)))
    assert len(rows) == 4 and all(key > 0 and node_id for key, node_id, _ in rows)
    assert abs(sum(score for _, _, score in rows) - 1) < 1e-10
finally:
    statement.close()
    db.close()
print("installed Python PageRank consumer: ok")
