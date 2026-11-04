from pathlib import Path

import pytest

import zova

FORMAT_9_FIXTURE = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "format-9.zova"


def create_with_entries(path):
    """A database whose verify pass covers far more items than the 101
    whole-percent steps Zova forwards."""
    db = zova.Database.create(str(path))
    for index in range(1000):
        db.kv_put(b"progress", index.to_bytes(8, "big"), b"progress")
    return db


def assert_well_formed(events):
    """Each phase/member group keeps its total, never decreases, and ends at total."""
    assert events
    for index, event in enumerate(events):
        assert event.done <= event.total
        following = events[index + 1] if index + 1 < len(events) else None
        if following is not None and (following.phase, following.member) == (event.phase, event.member):
            assert following.total == event.total
            assert following.done >= event.done
        else:
            assert event.done == event.total, event


def test_backup_and_compact_report_progress(tmp_path):
    with create_with_entries(tmp_path / "source.zova") as db:
        events = []
        db.backup_to(str(tmp_path / "backup.zova"), progress=events.append)
        assert_well_formed(events)
        assert (events[0].phase, events[0].member) == ("copy", "main")
        verify = [event for event in events if event.phase == "verify"]
        assert 1 < len(verify) <= 102
        assert all(event.member is None and event.total >= 1000 for event in verify)
        assert isinstance(events[0], zova.Progress)
        assert "copy" in repr(events[0])

        events = []
        db.compact_to(str(tmp_path / "compact.zova"), progress=events.append)
        assert_well_formed(events)


def test_exception_in_progress_cancels_and_propagates(tmp_path):
    class Stop(Exception):
        pass

    with create_with_entries(tmp_path / "source.zova") as db:
        calls = []

        def cancel(event):
            calls.append(event)
            raise Stop

        backup = tmp_path / "backup.zova"
        with pytest.raises(Stop):
            db.backup_to(str(backup), progress=cancel)
        assert len(calls) == 1
        assert not backup.exists()

        def cancel_in_verify(event):
            if event.phase == "verify" and event.done > 0:
                raise KeyboardInterrupt

        compact = tmp_path / "compact.zova"
        with pytest.raises(KeyboardInterrupt):
            db.compact_to(str(compact), progress=cancel_in_verify)
        assert not compact.exists()
        assert db.prepare("select 1").step() == zova.Step.ROW


def test_migrate_reports_progress_and_cancel_leaves_source_unchanged(tmp_path):
    source = tmp_path / "source.zova"
    source.write_bytes(FORMAT_9_FIXTURE.read_bytes())
    before = source.read_bytes()
    destination = tmp_path / "migrated.zova"

    def cancel_in_migrate(event):
        if event.phase == "migrate":
            raise RuntimeError("stop")

    with pytest.raises(RuntimeError, match="stop"):
        zova.migrate_database(str(source), str(destination), progress=cancel_in_migrate)
    assert not destination.exists()
    assert source.read_bytes() == before

    events = []
    zova.migrate_database(str(source), str(destination), progress=events.append)
    assert_well_formed(events)
    assert {"copy", "migrate", "verify", "publish"} <= {event.phase for event in events}
    assert (events[-1].phase, events[-1].member) == ("publish", None)
    zova.Database.open(str(destination)).close()
