import os

import pytest

from zova import Database, Step, ZovaError


def test_plugin_selection_rejects_invalid_bundle_before_mutation(tmp_path):
    path = tmp_path / "invalid.zova"
    with pytest.raises((ZovaError, ValueError)):
        Database.create(str(path), extension_bundles=["bad\0.zovaext"])
    assert not path.exists()


@pytest.mark.skipif(not os.environ.get("ZOVA_TEST_PLUGIN_BUNDLE"), reason="requires isolated portable plugin fixture")
def test_portable_plugin_package(tmp_path):
    options = dict(extension_bundles=[os.environ["ZOVA_TEST_PLUGIN_BUNDLE"]], trust_store_path=os.environ["ZOVA_TEST_PLUGIN_TRUST_STORE"])
    path = str(tmp_path / "plugin.zova")
    db = Database.create(path, **options)
    db.install_extension("c_test")
    statement = db.prepare("SELECT zova_c_test_cached()")
    db.close()  # Owned statements retain the connection and loaded code.
    assert statement.step() == Step.ROW
    assert statement.column_int(0) == 42
    statement.close()
    with pytest.raises(ZovaError):
        Database.open(path)
    db = Database.open(path, read_only=True, **options)
    db.check_extension("c_test")
    db.close()
