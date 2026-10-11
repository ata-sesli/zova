"""Run against an installed wheel, not the Python source directory."""
import os
from zova import Database, Step

db = Database.open(os.environ["ZOVA_USEARCH_DATABASE"], read_only=True,
    extension_bundles=[os.environ["ZOVA_USEARCH_BUNDLE"]],
    trust_store_path=os.environ["ZOVA_USEARCH_TRUST"])
statement = db.prepare("SELECT vector_id,distance FROM zova_usearch_search('points',x'0000000000000000',2,64)")
try:
    rows = []
    while statement.step() == Step.ROW:
        rows.append((statement.column_text(0), statement.column_float(1)))
    assert rows == [("one", 1.0), ("two", 2.0)]
finally:
    statement.close()
    db.close()
print("installed Python USearch consumer: ok")
