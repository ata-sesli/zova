import pytest

import zova

LEAVE_FREE_PAGES = (
    "create table scratch(data blob); "
    "with recursive n(i) as (select 1 union all select i + 1 from n where i < 300) "
    "insert into scratch select zeroblob(4000) from n; "
    "drop table scratch"
)


def test_reclaim_space_releases_free_pages_in_bounded_steps(tmp_path):
    with zova.Database.create(str(tmp_path / "reclaim.zova")) as db:
        db.exec(LEAVE_FREE_PAGES)

        bounded = db.reclaim_space(max_pages=100, step_pages=30)
        assert len(bounded) == 1
        first = bounded[0]
        assert isinstance(first, zova.ReclaimedMember)
        assert (first.member, first.auto_vacuum, first.page_size) == ("main", "incremental", 4096)
        assert first.pages_released == 100
        assert first.free_pages_left > 0

        rest = db.reclaim_space()
        assert rest[0].pages_released == first.free_pages_left
        assert rest[0].free_pages_left == 0

        db.begin()
        with pytest.raises(zova.ZovaError) as exc:
            db.reclaim_space()
        assert exc.value.status_name == "ZOVA_OBJECT_TRANSACTION_ACTIVE"
        db.rollback()


def test_reclaim_space_reports_none_mode(tmp_path):
    with zova.Database.create(str(tmp_path / "none.zova")) as db:
        db.exec("pragma auto_vacuum = none; vacuum")
        db.exec(LEAVE_FREE_PAGES)
        (member,) = db.reclaim_space()
        assert member.auto_vacuum == "none"
        assert member.pages_released == 0
        assert member.free_pages_left > 0
        assert "auto_vacuum='none'" in repr(member)
