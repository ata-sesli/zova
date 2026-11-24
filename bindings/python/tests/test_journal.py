import pytest

import zova


def test_set_journal_mode_switches_and_reports_the_set(tmp_path):
    path = str(tmp_path / "journal.zova")
    with zova.Database.create(path) as db:
        (member,) = db.journal_modes()
        assert isinstance(member, zova.JournalModeMember)
        assert (member.member, member.journal_mode) == ("main", "delete")

        (member,) = db.set_journal_mode("wal")
        assert member.journal_mode == "wal"
        assert "journal_mode='wal'" in repr(member)

        with pytest.raises(zova.ZovaError) as exc:
            db.set_journal_mode("off")
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"
        with pytest.raises(ValueError):
            db.set_journal_mode("bogus")

        db.begin()
        with pytest.raises(zova.ZovaError) as exc:
            db.set_journal_mode("delete")
        assert exc.value.status_name == "ZOVA_OBJECT_TRANSACTION_ACTIVE"
        db.rollback()

    # WAL is stored in the file.
    with zova.Database.open(path) as db:
        assert db.journal_modes()[0].journal_mode == "wal"
        assert db.set_journal_mode("delete")[0].journal_mode == "delete"


def test_checkpoint_reports_wal_frames(tmp_path):
    with zova.Database.create(str(tmp_path / "checkpoint.zova")) as db:
        (member,) = db.checkpoint()
        assert (member.journal_mode, member.wal_frames, member.busy) == ("delete", 0, False)

        db.set_journal_mode("wal")
        db.exec("create table rows(x); insert into rows values(1)")
        (member,) = db.checkpoint("passive")
        assert isinstance(member, zova.CheckpointedMember)
        assert member.wal_frames > 0
        assert member.checkpointed_frames == member.wal_frames
        assert db.checkpoint("truncate")[0].wal_frames == 0
        with pytest.raises(ValueError):
            db.checkpoint("sometimes")


def test_in_memory_database_keeps_memory_mode():
    with zova.Database.create_memory() as db:
        assert db.journal_modes()[0].journal_mode == "memory"
        with pytest.raises(zova.ZovaError) as exc:
            db.set_journal_mode("wal")
        assert exc.value.status_name == "ZOVA_INVALID_ARGUMENT"
