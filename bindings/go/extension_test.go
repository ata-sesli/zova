package zova

import "testing"

func TestExtensionLifecycleManageBundledTrgm(t *testing.T) {
	path := tempZovaPath(t, "extensions")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	extensions, err := db.ListExtensions()
	if err != nil {
		t.Fatal(err)
	}
	if len(extensions) != 0 {
		t.Fatalf("new database extensions = %#v", extensions)
	}

	if err := db.InstallExtension("missing_ext"); !errorStatusIs(err, StatusExtensionNotFound) {
		t.Fatalf("missing InstallExtension error = %v, want StatusExtensionNotFound", err)
	}
	must(t, db.InstallExtension("trgm"))
	if err := db.InstallExtension("trgm"); !errorStatusIs(err, StatusExtensionExists) {
		t.Fatalf("duplicate InstallExtension error = %v, want StatusExtensionExists", err)
	}

	info, err := db.ExtensionInfo("trgm")
	if err != nil {
		t.Fatal(err)
	}
	if info.Name != "trgm" || info.StoragePrefix != "_zova_ext_trgm_" || info.Capabilities != "sql,trgm" || !info.Required {
		t.Fatalf("ExtensionInfo = %#v", info)
	}
	if info.InstalledAtUnix <= 0 {
		t.Fatalf("InstalledAtUnix = %d", info.InstalledAtUnix)
	}
	if info.ManifestJSON == "" {
		t.Fatalf("ManifestJSON is empty")
	}

	extensions, err = db.ListExtensions()
	if err != nil {
		t.Fatal(err)
	}
	if len(extensions) != 1 || extensions[0].Name != "trgm" {
		t.Fatalf("ListExtensions = %#v", extensions)
	}
	must(t, db.CheckExtension("trgm"))
	must(t, db.CheckExtensions())

	create, err := db.Prepare("select zova_trgm_create_index('messages')")
	if err != nil {
		t.Fatal(err)
	}
	if step, err := create.Step(); err != nil || step != StepRow {
		t.Fatalf("trgm create index step = %v, %v", step, err)
	}
	must(t, create.Close())

	must(t, db.DropExtension("trgm"))
	if _, err := db.ExtensionInfo("trgm"); !errorStatusIs(err, StatusExtensionNotFound) {
		t.Fatalf("dropped ExtensionInfo error = %v, want StatusExtensionNotFound", err)
	}
}

func TestExtensionLifecycleUseAfterClose(t *testing.T) {
	path := tempZovaPath(t, "extension-closed")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.Close())
	if err := db.InstallExtension("trgm"); !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("InstallExtension after close error = %v, want StatusMisuse", err)
	}
}
