package zova

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func tempZovaPath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join(t.TempDir(), name+".zova")
}

func TestABIVersionAndStatusNames(t *testing.T) {
	major, minor, patch := ABIVersionNumbers()
	if major != 0 || minor != 13 || patch != 1 {
		t.Fatalf("unexpected ABI version: %d.%d.%d", major, minor, patch)
	}
	if got := ABIVersion(); got != "0.13.1" {
		t.Fatalf("unexpected ABI version string: %q", got)
	}
	if got := StatusName(StatusOK); got != "ZOVA_OK" {
		t.Fatalf("unexpected OK status name: %q", got)
	}
}

func TestCreateOpenExecAndPreparedStatements(t *testing.T) {
	path := tempZovaPath(t, "records")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.Exec(`create table records(
		id integer primary key,
		name text not null,
		score real not null,
		note text,
		data blob,
		empty_text text not null,
		empty_blob blob not null
	)`); err != nil {
		t.Fatal(err)
	}

	insert, err := db.Prepare(`insert into records(
		id, name, score, note, data, empty_text, empty_blob
	) values (:id, :name, ?3, ?4, ?5, ?6, ?7)`)
	if err != nil {
		t.Fatal(err)
	}
	defer insert.Close()

	if count, err := insert.ParameterCount(); err != nil || count != 7 {
		t.Fatalf("parameter count = %d, %v", count, err)
	}
	if index, err := insert.ParameterIndex(":name"); err != nil || index != 2 {
		t.Fatalf("parameter index = %d, %v", index, err)
	}
	if index, err := insert.ParameterIndex(":missing"); err != nil || index != 0 {
		t.Fatalf("missing parameter index = %d, %v", index, err)
	}

	must(t, insert.BindInt64(1, 7))
	must(t, insert.BindText(2, "hello"))
	must(t, insert.BindFloat64(3, 3.5))
	must(t, insert.BindNull(4))
	must(t, insert.BindBlob(5, []byte{0, 1, 2, 3}))
	must(t, insert.BindText(6, ""))
	must(t, insert.BindBlob(7, []byte{}))
	if step, err := insert.Step(); err != nil || step != StepDone {
		t.Fatalf("insert step = %v, %v", step, err)
	}
	must(t, insert.Close())

	query, err := db.Prepare(`select id, name, score, note, data, empty_text, empty_blob from records where id = ?1`)
	if err != nil {
		t.Fatal(err)
	}
	defer query.Close()
	must(t, query.BindInt64(1, 7))
	if step, err := query.Step(); err != nil || step != StepRow {
		t.Fatalf("query step = %v, %v", step, err)
	}
	if count, err := query.ColumnCount(); err != nil || count != 7 {
		t.Fatalf("column count = %d, %v", count, err)
	}
	if typ, err := query.ColumnType(3); err != nil || typ != ColumnNull {
		t.Fatalf("note type = %v, %v", typ, err)
	}
	if id, err := query.ColumnInt64(0); err != nil || id != 7 {
		t.Fatalf("id = %d, %v", id, err)
	}
	if name, ok, err := query.ColumnText(1); err != nil || !ok || name != "hello" {
		t.Fatalf("name = %q %v, %v", name, ok, err)
	}
	if score, err := query.ColumnFloat64(2); err != nil || score != 3.5 {
		t.Fatalf("score = %f, %v", score, err)
	}
	if note, ok, err := query.ColumnText(3); err != nil || ok || note != "" {
		t.Fatalf("note = %q %v, %v", note, ok, err)
	}
	if data, ok, err := query.ColumnBlob(4); err != nil || !ok || !bytes.Equal(data, []byte{0, 1, 2, 3}) {
		t.Fatalf("data = %v %v, %v", data, ok, err)
	}
	if text, ok, err := query.ColumnText(5); err != nil || !ok || text != "" {
		t.Fatalf("empty text = %q %v, %v", text, ok, err)
	}
	if blob, ok, err := query.ColumnBlob(6); err != nil || !ok || len(blob) != 0 {
		t.Fatalf("empty blob = %v %v, %v", blob, ok, err)
	}
	if step, err := query.Step(); err != nil || step != StepDone {
		t.Fatalf("done step = %v, %v", step, err)
	}
}

func TestResetClearBindingsTransactionsVacuumAndMultipleHandles(t *testing.T) {
	path := tempZovaPath(t, "lifecycle")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	must(t, db.Exec("create table items(id integer primary key, body text not null)"))

	stmt, err := db.Prepare("select ?1")
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	must(t, stmt.BindText(1, "sticky"))
	assertSingleText(t, stmt, "sticky", true)
	must(t, stmt.Reset())
	assertSingleText(t, stmt, "sticky", true)
	must(t, stmt.Reset())
	must(t, stmt.ClearBindings())
	assertSingleText(t, stmt, "", false)
	must(t, stmt.Close())

	must(t, db.Begin())
	must(t, db.Exec("insert into items(body) values ('rolled back')"))
	must(t, db.Rollback())
	if got := scalarInt(t, db, "select count(*) from items"); got != 0 {
		t.Fatalf("rollback count = %d", got)
	}

	must(t, db.BeginImmediate())
	must(t, db.Exec("insert into items(body) values ('committed')"))
	must(t, db.Commit())
	if got := scalarInt(t, db, "select count(*) from items"); got != 1 {
		t.Fatalf("commit count = %d", got)
	}

	must(t, db.Vacuum())

	second, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if got := scalarInt(t, second, "select count(*) from items"); got != 1 {
		t.Fatalf("second handle count = %d", got)
	}
}

func TestConversionInteriorNULAndUseAfterClose(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.db")
	destination := filepath.Join(dir, "converted.zova")
	createPlainSQLite(t, source)

	if err := ConvertSqliteToZova(source, destination); err != nil {
		t.Fatal(err)
	}
	db, err := Open(destination)
	if err != nil {
		t.Fatal(err)
	}
	if got := scalarInt(t, db, "select count(*) from source_rows"); got != 1 {
		t.Fatalf("converted row count = %d", got)
	}
	stmt, err := db.Prepare("select body from source_rows where id = 1")
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("select 1"); err == nil {
		t.Fatal("Exec after Close returned nil error")
	}
	if _, err := stmt.Step(); err == nil {
		t.Fatal("Step after DB Close returned nil error")
	}

	if _, err := Create("bad\x00path.zova"); err == nil {
		t.Fatal("Create accepted path with NUL")
	}

	db2, err := Create(filepath.Join(dir, "nul.zova"))
	if err != nil {
		t.Fatal(err)
	}
	defer db2.Close()
	if err := db2.Exec("select '\x00'"); err == nil {
		t.Fatal("Exec accepted SQL with NUL")
	}
}

func assertSingleText(t *testing.T, stmt *Stmt, want string, wantOK bool) {
	t.Helper()
	step, err := stmt.Step()
	if err != nil {
		t.Fatal(err)
	}
	if step != StepRow {
		t.Fatalf("step = %v, want row", step)
	}
	got, ok, err := stmt.ColumnText(0)
	if err != nil {
		t.Fatal(err)
	}
	if got != want || ok != wantOK {
		t.Fatalf("text = %q %v, want %q %v", got, ok, want, wantOK)
	}
	step, err = stmt.Step()
	if err != nil {
		t.Fatal(err)
	}
	if step != StepDone {
		t.Fatalf("step = %v, want done", step)
	}
}

func scalarInt(t *testing.T, db *DB, sql string) int64 {
	t.Helper()
	stmt, err := db.Prepare(sql)
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	step, err := stmt.Step()
	if err != nil {
		t.Fatal(err)
	}
	if step != StepRow {
		t.Fatalf("step = %v, want row", step)
	}
	value, err := stmt.ColumnInt64(0)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func createPlainSQLite(t *testing.T, path string) {
	t.Helper()
	const fixture = "" +
		"H4sIAAAAAAAC/+3XOwrCQBAG4NkoWPloxHYgjYLYeAGjpLPx0UvUjSwmrm42aEoPId7J03gEIyqKjb38H/PDDDMXmMloqKzk" +
		"UJs4sNylGglBPWYicp55EXmKX/MvDnVOl/L9uHqmvAAAAAAAAADgbSVKDdcVx7oN5pFMdGoWcmb0PvloncHY96Y+T73+0OeP" +
		"RVMtWW2sXEnDW6PiwGS8llmb53qZsZUHyxudJ42i1uM3v1JeAAAAAAAAAPAnKqJAbmh0zMkuUlbeAKwNvTMAIAAA"
	compressed, err := base64.StdEncoding.DecodeString(fixture)
	if err != nil {
		t.Fatal(err)
	}
	reader, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func Example() {
	path := filepath.Join(os.TempDir(), "zova-go-example.zova")
	_ = os.Remove(path)
	db, err := Create(path)
	if err != nil {
		panic(err)
	}
	defer db.Close()
	defer os.Remove(path)

	if err := db.Exec("create table notes(id integer primary key, body text not null)"); err != nil {
		panic(err)
	}
	insert, err := db.Prepare("insert into notes(body) values (?1)")
	if err != nil {
		panic(err)
	}
	defer insert.Close()
	if err := insert.BindText(1, "hello from Go"); err != nil {
		panic(err)
	}
	step, err := insert.Step()
	if err != nil {
		panic(err)
	}
	fmt.Println(step == StepDone)
	// Output: true
}
