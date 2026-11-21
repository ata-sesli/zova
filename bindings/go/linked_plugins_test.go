package zova

import (
	"path/filepath"
	"testing"

	"github.com/ata-sesli/zova/bindings/go/internal/testplugin"
)

func linkedPlugins() []LinkedPlugin {
	return []LinkedPlugin{{Descriptor: testplugin.Descriptor()}}
}

func TestCreateWithOptionsSetsThePageSize(t *testing.T) {
	path := tempZovaPath(t, "page-size")
	db, err := CreateWithOptions(path, CreateOptions{PageSize: 8192})
	must(t, err)
	if got := queryInt(t, db, "pragma page_size"); got != 8192 {
		t.Fatalf("page_size = %d", got)
	}
	must(t, db.Close())
	if _, err := CreateWithOptions(path, CreateOptions{}); err == nil {
		t.Fatal("CreateWithOptions over an existing file succeeded")
	}
}

func TestLinkedPluginsOpenUpgradeAndRebuild(t *testing.T) {
	path := tempZovaPath(t, "linked")
	none := ExtensionOptions{}
	db, err := CreateWithPlugins(path, none, linkedPlugins())
	must(t, err)
	must(t, db.InstallExtension("linked_test"))
	must(t, db.Close())

	if _, err := Open(path); !errorStatusIs(err, StatusExtensionUnavailable) {
		t.Fatalf("Open without plugin = %v", err)
	}
	if _, err := OpenWithPlugins(path, OpenOptions{}, none, nil); !errorStatusIs(err, StatusExtensionUnavailable) {
		t.Fatalf("OpenWithPlugins without plugin = %v", err)
	}
	db, err = OpenWithPlugins(path, OpenOptions{}, none, linkedPlugins())
	must(t, err)
	info, err := db.ExtensionInfo("linked_test")
	if err != nil || info.Version != "1.0.0" {
		t.Fatalf("ExtensionInfo = %+v, %v", info, err)
	}
	must(t, db.Close())

	db, err = OpenForExtensionUpgradeWithPlugins(path, OpenOptions{}, none, linkedPlugins())
	must(t, err)
	// The descriptor declares no newer version and no recovery hook.
	if err := db.ExtensionUpgrade("linked_test"); !errorStatusIs(err, StatusExtensionIncompatible) {
		t.Fatalf("ExtensionUpgrade = %v", err)
	}
	if err := db.ExtensionRebuild("linked_test"); !errorStatusIs(err, StatusExtensionUnavailable) {
		t.Fatalf("ExtensionRebuild = %v", err)
	}
	must(t, db.Close())

	// The maintenance open skips hooks, so it succeeds without the code; the
	// upgrade then reports the missing code.
	db, err = OpenForExtensionUpgrade(path, OpenOptions{}, none)
	must(t, err)
	if err := db.ExtensionUpgrade("linked_test"); !errorStatusIs(err, StatusExtensionUnavailable) {
		t.Fatalf("ExtensionUpgrade without code = %v", err)
	}
	must(t, db.Close())

	err = MigrateDatabaseWithPlugins(path, filepath.Join(t.TempDir(), "not-migrated.zova"), MigrateOptions{}, none, linkedPlugins())
	if !errorStatusIs(err, StatusNoMigrationPath) {
		t.Fatalf("migrate current format = %v", err)
	}
}

func TestMigrationAcceptsLinkedPlugins(t *testing.T) {
	fixture := migrationFixturePath(t, "format-9.zova")
	dir := t.TempDir()
	none := ExtensionOptions{}
	destination := filepath.Join(dir, "migrated.zova")
	must(t, MigrateDatabaseWithPlugins(fixture, destination, MigrateOptions{}, none, linkedPlugins()))
	db, err := OpenWithPlugins(destination, OpenOptions{}, none, linkedPlugins())
	must(t, err)
	must(t, db.Close())

	events := 0
	must(t, MigrateDatabaseWithPluginsAndProgress(fixture, filepath.Join(dir, "progress.zova"), MigrateOptions{}, none, linkedPlugins(), func(Progress) error {
		events++
		return nil
	}))
	if events == 0 {
		t.Fatal("no progress events")
	}
}

func TestBundleTrustFunctionsReportNativeErrors(t *testing.T) {
	dir := t.TempDir()
	trust := filepath.Join(dir, "trust.json")
	missing := filepath.Join(dir, "missing.zovaext")
	if err := VerifyExtensionBundle(missing, trust); err == nil {
		t.Fatal("VerifyExtensionBundle(missing) succeeded")
	}
	if err := TrustExtensionBundle(missing, trust); err == nil {
		t.Fatal("TrustExtensionBundle(missing) succeeded")
	}
	removed, err := UntrustExtensionBundle("never_trusted", trust)
	if err != nil || removed {
		t.Fatalf("UntrustExtensionBundle = %v, %v", removed, err)
	}
	if _, err := UntrustExtensionBundle("bad\x00name", trust); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("NUL identifier = %v", err)
	}
}
