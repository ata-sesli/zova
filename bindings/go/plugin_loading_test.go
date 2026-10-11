package zova

import (
	"os"
	"testing"
)

func TestPluginSelectionRejectsNulBeforeMutation(t *testing.T) {
	path := tempZovaPath(t, "invalid-plugin")
	_, err := CreateWithExtensions(path, ExtensionOptions{BundlePaths: []string{"bad\x00.zovaext"}})
	if err == nil {
		t.Fatal("accepted invalid bundle path")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("created database before validation: %v", err)
	}
}

func TestPortablePluginPackage(t *testing.T) {
	bundle := os.Getenv("ZOVA_TEST_PLUGIN_BUNDLE")
	if bundle == "" {
		t.Skip("requires isolated portable plugin package fixture")
	}
	options := ExtensionOptions{BundlePaths: []string{bundle}, TrustStorePath: os.Getenv("ZOVA_TEST_PLUGIN_TRUST_STORE")}
	path := tempZovaPath(t, "portable-plugin")
	db, err := CreateWithExtensions(path, options)
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.InstallExtension("c_test"))
	stmt, err := db.Prepare("SELECT zova_c_test_cached()")
	if err != nil {
		t.Fatal(err)
	}
	step, err := stmt.Step()
	if err != nil || step != StepRow {
		t.Fatalf("step: %v %v", step, err)
	}
	value, err := stmt.ColumnInt64(0)
	if err != nil || value != 42 {
		t.Fatalf("result: %v %v", value, err)
	}
	must(t, db.Close()) // Go closes owned children before unloading libraries.
	if _, err := Open(path); !errorStatusIs(err, StatusExtensionUnavailable) {
		t.Fatalf("metadata loaded code: %v", err)
	}
	db, err = OpenWithExtensions(path, OpenOptions{ReadOnly: true}, options)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	must(t, db.CheckExtension("c_test"))
}
