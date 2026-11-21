import ctypes
import shutil
from pathlib import Path

import pytest

import zova

FORMAT_9_FIXTURE = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "format-9.zova"


class PluginDescriptor(ctypes.Structure):
    """`zova_plugin_descriptor_v1` from include/zova_plugin.h."""

    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("flags", ctypes.c_uint64),
        ("name", ctypes.c_char_p),
        ("version", ctypes.c_char_p),
        ("storage_prefix", ctypes.c_char_p),
        ("zova_abi_min", ctypes.c_char_p),
        ("capabilities", ctypes.c_char_p),
        ("install", ctypes.c_void_p),
        ("check", ctypes.c_void_p),
        ("drop", ctypes.c_void_p),
        ("register_sql", ctypes.c_void_p),
    ]


# Module-level so the descriptor and its strings outlive every database.
_DESCRIPTOR = PluginDescriptor(
    ctypes.sizeof(PluginDescriptor),
    1,
    0,
    b"linked_test",
    b"1.0.0",
    b"_zova_ext_linked_test_",
    b"1.0.0",
    None,
)


def linked():
    return zova.LinkedPlugin.from_address(ctypes.addressof(_DESCRIPTOR))


def test_abi_version_matches_its_string():
    major, minor, patch = zova.abi_version()
    assert zova.abi_version_string() == f"{major}.{minor}.{patch}"


def test_create_with_page_size(tmp_path):
    path = str(tmp_path / "pages.zova")
    with zova.Database.create(path, page_size=8192) as db:
        statement = db.prepare("pragma page_size")
        assert statement.step() == zova.Step.ROW
        assert statement.column_int(0) == 8192
        statement.close()
    with pytest.raises(ValueError):
        zova.Database.create(str(tmp_path / "x.zova"), page_size=4096, plugins=[linked()])
    with pytest.raises(ValueError):
        zova.LinkedPlugin.from_address(0)


def test_linked_plugins_open_upgrade_and_rebuild(tmp_path):
    path = str(tmp_path / "linked.zova")
    with zova.Database.create(path, plugins=[linked()]) as db:
        db.install_extension("linked_test")

    with pytest.raises(zova.ZovaError) as error:
        zova.Database.open(path)
    assert error.value.status_name == "ZOVA_EXTENSION_UNAVAILABLE"
    with zova.Database.open(path, plugins=[linked()]) as db:
        assert db.extension_info("linked_test").version == "1.0.0"

    with zova.Database.open_for_extension_upgrade(path, plugins=[linked()]) as db:
        # The descriptor declares no newer version and no recovery hook.
        with pytest.raises(zova.ZovaError) as error:
            db.extension_upgrade("linked_test")
        assert error.value.status_name == "ZOVA_EXTENSION_INCOMPATIBLE"
        with pytest.raises(zova.ZovaError) as error:
            db.extension_rebuild("linked_test")
        assert error.value.status_name == "ZOVA_EXTENSION_UNAVAILABLE"

    # The maintenance open skips hooks, so it succeeds without the code.
    with zova.Database.open_for_extension_upgrade(path) as db:
        with pytest.raises(zova.ZovaError) as error:
            db.extension_upgrade("linked_test")
        assert error.value.status_name == "ZOVA_EXTENSION_UNAVAILABLE"

    with pytest.raises(zova.ZovaError) as error:
        zova.migrate_database(path, str(tmp_path / "no.zova"), plugins=[linked()])
    assert error.value.status_name == "ZOVA_NO_MIGRATION_PATH"


def test_migration_accepts_linked_plugins(tmp_path):
    source = tmp_path / "source.zova"
    shutil.copyfile(FORMAT_9_FIXTURE, source)
    destination = str(tmp_path / "migrated.zova")
    zova.migrate_database(str(source), destination, plugins=[linked()])
    zova.Database.open(destination, plugins=[linked()]).close()

    events = []
    zova.migrate_database(
        str(source), str(tmp_path / "progress.zova"), plugins=[linked()], progress=events.append
    )
    assert events


def test_bundle_trust_functions_report_native_errors(tmp_path):
    trust = str(tmp_path / "trust.json")
    missing = str(tmp_path / "missing.zovaext")
    with pytest.raises(zova.ZovaError):
        zova.verify_extension_bundle(missing, trust_store_path=trust)
    with pytest.raises(zova.ZovaError):
        zova.trust_extension_bundle(missing, trust_store_path=trust)
    assert zova.untrust_extension_bundle("never_trusted", trust_store_path=trust) is False
    with pytest.raises(ValueError):
        zova.untrust_extension_bundle("bad\0name", trust_store_path=trust)
