from pathlib import Path

import zova


def test_bundled_sqlite_capabilities(tmp_path):
    sql = Path(__file__).resolve().parents[3] / "tests/sqlite_capabilities.sql"
    with zova.Database.create(str(tmp_path / "capabilities.zova")) as db:
        db.exec(sql.read_text())
