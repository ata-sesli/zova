import hashlib
from pathlib import Path

import pytest

import zova

FIXTURES = Path(__file__).resolve().parents[3] / "tests" / "fixtures"
FORMAT_9_FIXTURE = FIXTURES / "format-9.zova"
FORMAT_9_SHA256 = "6d7371d9c9d45c07c568989c738f83ec9fae7470ab3c73523bdf6ab71387bc11"


def copy_fixture(tmp_path, name="migrate-source.zova"):
    source = tmp_path / name
    source.write_bytes(FORMAT_9_FIXTURE.read_bytes())
    return source


def test_fixture_matches_released_hash():
    digest = hashlib.sha256(FORMAT_9_FIXTURE.read_bytes()).hexdigest()
    assert digest == FORMAT_9_SHA256


def test_probe_format_classifies_formats(tmp_path):
    source = copy_fixture(tmp_path)
    before = source.read_bytes()

    info = zova.probe_format(str(source))
    assert info.format_version == 9
    assert info.compatibility == "migratable"
    assert zova.FormatCompatibility.MIGRATABLE.name_value == "migratable"

    current = tmp_path / "current.zova"
    with zova.Database.create(str(current)) as db:
        db.exec("create table t(id integer)")
    info = zova.probe_format(str(current))
    assert info.format_version == 10
    assert info.compatibility == "current"

    assert source.read_bytes() == before


def test_probe_format_rejects_non_zova_paths(tmp_path):
    path = tmp_path / "not-zova.txt"
    path.write_bytes(b"not a zova file")
    with pytest.raises(zova.ZovaError) as exc:
        zova.probe_format(str(path))
    assert exc.value.status_name == "ZOVA_NOT_ZOVA_PATH"


def test_migrate_fixture_forward_and_reopen(tmp_path):
    source = copy_fixture(tmp_path)
    destination = tmp_path / "migrate-destination.zova"
    before = source.read_bytes()

    zova.migrate_database(str(source), str(destination))

    info = zova.probe_format(str(destination))
    assert info.format_version == 10
    assert info.compatibility == "current"
    assert source.read_bytes() == before

    with zova.Database.open(str(destination)) as db:
        with db.prepare("select count(*) from user_documents") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_int(0) == 3
            assert stmt.step() == zova.Step.DONE
        with db.prepare("select value from user_settings where key = 'theme'") as stmt:
            assert stmt.step() == zova.Step.ROW
            assert stmt.column_text(0) == "dark;light\nwith\ndelimiter"
            assert stmt.step() == zova.Step.DONE
        db.exec("create table post_migration(id integer primary key, note text)")
        db.exec("insert into post_migration(note) values ('hello')")


def test_migrate_no_verify_flag(tmp_path):
    source = copy_fixture(tmp_path)
    destination = tmp_path / "migrate-no-verify.zova"

    zova.migrate_database(str(source), str(destination), verify=False)
    info = zova.probe_format(str(destination))
    assert info.format_version == 10
    assert info.compatibility == "current"


def test_migrate_failure_statuses(tmp_path):
    source = copy_fixture(tmp_path)
    destination = tmp_path / "migrate-fail-destination.zova"
    destination.write_bytes(b"occupied")

    with pytest.raises(zova.ZovaError) as exc:
        zova.migrate_database(str(source), str(destination))
    assert exc.value.status_name == "ZOVA_DESTINATION_EXISTS"

    with pytest.raises(zova.ZovaError) as exc:
        zova.migrate_database(str(tmp_path / "missing.zova"), str(destination))
    assert exc.value.status_name == "ZOVA_CANT_OPEN"
