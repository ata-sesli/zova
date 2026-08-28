package zova

import (
	"os"
	"path/filepath"
	"testing"
)

func migrationFixturePath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join("..", "..", "tests", "fixtures", name)
}

func copyMigrationFixture(t *testing.T, name string) string {
	t.Helper()
	source := migrationFixturePath(t, name)
	destination := tempZovaPath(t, "migrate-"+name)
	bytes, err := os.ReadFile(source)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err := os.WriteFile(destination, bytes, 0o644); err != nil {
		t.Fatalf("write fixture copy: %v", err)
	}
	t.Cleanup(func() { _ = os.Remove(destination) })
	return destination
}

func readAllBytes(t *testing.T, path string) []byte {
	t.Helper()
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return bytes
}

func sameBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for index := range a {
		if a[index] != b[index] {
			return false
		}
	}
	return true
}

func TestProbeFormatClassifiesFormats(t *testing.T) {
	fixture := migrationFixturePath(t, "format-9.zova")
	before := readAllBytes(t, fixture)

	info, err := ProbeFormat(fixture)
	if err != nil {
		t.Fatalf("ProbeFormat(format-9) = %v", err)
	}
	if info.FormatVersion != 9 || info.Compatibility != FormatMigratable {
		t.Fatalf("ProbeFormat(format-9) = %+v, want format 9 migratable", info)
	}
	if name := FormatCompatibilityName(info.Compatibility); name != "migratable" {
		t.Fatalf("compatibility name = %q, want migratable", name)
	}

	current := tempZovaPath(t, "probe-current")
	db, err := Create(current)
	if err != nil {
		t.Fatalf("Create = %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("Close = %v", err)
	}
	info, err = ProbeFormat(current)
	if err != nil {
		t.Fatalf("ProbeFormat(current) = %v", err)
	}
	if info.FormatVersion != 10 || info.Compatibility != FormatCurrent {
		t.Fatalf("ProbeFormat(current) = %+v, want format 10 current", info)
	}
	if name := FormatCompatibilityName(info.Compatibility); name != "current" {
		t.Fatalf("compatibility name = %q, want current", name)
	}

	if after := readAllBytes(t, fixture); !sameBytes(before, after) {
		t.Fatalf("ProbeFormat mutated the fixture")
	}
}

func TestProbeFormatRejectsNonZovaPaths(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-zova.txt")
	if err := os.WriteFile(path, []byte("not a zova file"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := ProbeFormat(path); !errorStatusIs(err, StatusNotZovaPath) {
		t.Fatalf("ProbeFormat(not-zova) = %v, want StatusNotZovaPath", err)
	}
}

func TestMigrateFixtureForwardAndReopen(t *testing.T) {
	source := copyMigrationFixture(t, "format-9.zova")
	destination := tempZovaPath(t, "migrate-destination")
	before := readAllBytes(t, source)

	if err := MigrateDatabase(source, destination); err != nil {
		t.Fatalf("MigrateDatabase = %v", err)
	}

	info, err := ProbeFormat(destination)
	if err != nil {
		t.Fatalf("ProbeFormat(destination) = %v", err)
	}
	if info.FormatVersion != 10 || info.Compatibility != FormatCurrent {
		t.Fatalf("ProbeFormat(destination) = %+v, want format 10 current", info)
	}
	if after := readAllBytes(t, source); !sameBytes(before, after) {
		t.Fatalf("MigrateDatabase mutated the source")
	}

	db, err := Open(destination)
	if err != nil {
		t.Fatalf("Open(destination) = %v", err)
	}
	defer func() { _ = db.Close() }()

	stmt, err := db.Prepare("select count(*) from user_documents")
	if err != nil {
		t.Fatalf("Prepare = %v", err)
	}
	defer func() { _ = stmt.Close() }()
	if step, err := stmt.Step(); err != nil || step != StepRow {
		t.Fatalf("Step = %v, %v; want StepRow", step, err)
	}
	if count, err := stmt.ColumnInt64(0); err != nil || count != 3 {
		t.Fatalf("user_documents count = %d, %v; want 3", count, err)
	}

	if err := db.Exec("create table post_migration(id integer primary key, note text)"); err != nil {
		t.Fatalf("Exec = %v", err)
	}
}

func TestMigrateNoVerifyFlag(t *testing.T) {
	source := copyMigrationFixture(t, "format-9.zova")
	destination := tempZovaPath(t, "migrate-no-verify")

	if err := MigrateDatabase(source, destination, MigrateOptions{NoVerify: true}); err != nil {
		t.Fatalf("MigrateDatabase(no-verify) = %v", err)
	}
	info, err := ProbeFormat(destination)
	if err != nil {
		t.Fatalf("ProbeFormat = %v", err)
	}
	if info.FormatVersion != 10 || info.Compatibility != FormatCurrent {
		t.Fatalf("ProbeFormat = %+v, want format 10 current", info)
	}
}

func TestMigrateFailureStatuses(t *testing.T) {
	source := copyMigrationFixture(t, "format-9.zova")
	destination := tempZovaPath(t, "migrate-fail-destination")
	if err := os.WriteFile(destination, []byte("occupied"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := MigrateDatabase(source, destination); !errorStatusIs(err, StatusDestinationExists) {
		t.Fatalf("MigrateDatabase(existing) = %v, want StatusDestinationExists", err)
	}
	if err := MigrateDatabase(tempZovaPath(t, "missing"), destination); !errorStatusIs(err, StatusCantOpen) {
		t.Fatalf("MigrateDatabase(missing) = %v, want StatusCantOpen", err)
	}
}
