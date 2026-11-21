package zova

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
)

func describeArgs(args []any) (any, error) {
	parts := make([]string, len(args))
	for i, arg := range args {
		switch v := arg.(type) {
		case nil:
			parts[i] = "null"
		case int64:
			parts[i] = fmt.Sprintf("i:%d", v)
		case float64:
			parts[i] = fmt.Sprintf("f:%g", v)
		case string:
			parts[i] = "t:" + v
		case []byte:
			parts[i] = fmt.Sprintf("b:%d", len(v))
		}
	}
	return strings.Join(parts, ","), nil
}

func TestSQLFunctionsReceiveArgumentsAndReturnEveryResultType(t *testing.T) {
	db := memoryDB(t)
	must(t, db.RegisterFunction("describe", -1, SQLFunctionFlags{Deterministic: true}, describeArgs))
	must(t, db.RegisterFunction("pick", 1, SQLFunctionFlags{}, func(args []any) (any, error) {
		switch args[0] {
		case int64(0):
			return nil, nil
		case int64(1):
			return 7, nil
		case int64(2):
			return 2.5, nil
		case int64(3):
			return []byte{1, 2, 3}, nil
		case int64(4):
			return struct{}{}, nil
		}
		return nil, errors.New("pick: unsupported")
	}))

	stmt, err := db.Prepare("select describe(null, 1, 1.5, 'x', x'0102'), pick(0), pick(1), pick(2), pick(3)")
	must(t, err)
	if step, err := stmt.Step(); err != nil || step != StepRow {
		t.Fatalf("step: %v %v", step, err)
	}
	if text, _, _ := stmt.ColumnText(0); text != "null,i:1,f:1.5,t:x,b:2" {
		t.Fatalf("describe = %q", text)
	}
	if kind, _ := stmt.ColumnType(1); kind != ColumnNull {
		t.Fatalf("pick(0) type = %v", kind)
	}
	if value, _ := stmt.ColumnInt64(2); value != 7 {
		t.Fatalf("pick(1) = %d", value)
	}
	if value, _ := stmt.ColumnFloat64(3); value != 2.5 {
		t.Fatalf("pick(2) = %g", value)
	}
	if blob, _, _ := stmt.ColumnBlob(4); string(blob) != "\x01\x02\x03" {
		t.Fatalf("pick(3) = %v", blob)
	}
	must(t, stmt.Close())

	if err := db.Exec("select pick(9)"); err == nil || !strings.Contains(err.Error(), "pick: unsupported") {
		t.Fatalf("error result = %v", err)
	}
	if err := db.Exec("select pick(4)"); err == nil || !strings.Contains(err.Error(), "unsupported SQL function result type") {
		t.Fatalf("bad result type = %v", err)
	}
}

func TestSQLFunctionPanicsBecomeSQLErrors(t *testing.T) {
	db := memoryDB(t)
	must(t, db.RegisterFunction("boom", 0, SQLFunctionFlags{}, func([]any) (any, error) { panic("boom") }))
	if err := db.Exec("select boom()"); err == nil || !strings.Contains(err.Error(), "panicked") {
		t.Fatalf("panic = %v", err)
	}
	must(t, db.Exec("select 1"))
}

func TestInvalidSQLFunctionRegistrationsAreRejected(t *testing.T) {
	db := memoryDB(t)
	noop := func([]any) (any, error) { return nil, nil }
	for _, tc := range []struct {
		name  string
		arity int
	}{{"zova_reserved", 0}, {"bad name", 0}, {"", 0}, {"ok", 128}, {"ok", 1 << 40}} {
		if err := db.RegisterFunction(tc.name, tc.arity, SQLFunctionFlags{}, noop); !errorStatusIs(err, StatusInvalidArgument) {
			t.Fatalf("RegisterFunction(%q, %d) = %v", tc.name, tc.arity, err)
		}
	}
	if err := db.RegisterFunction("nilfn", 0, SQLFunctionFlags{}, nil); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("nil function = %v", err)
	}
	must(t, db.RegisterFunction("once", 0, SQLFunctionFlags{}, noop))
	if err := db.RegisterFunction("once", 0, SQLFunctionFlags{}, noop); err == nil {
		t.Fatal("duplicate registration succeeded")
	}
	must(t, db.RegisterFunction("once", 1, SQLFunctionFlags{}, noop))
}

func TestSQLFunctionsRunFromManyGoroutines(t *testing.T) {
	db := memoryDB(t)
	var mu sync.Mutex
	calls := 0
	must(t, db.RegisterFunction("bump", 1, SQLFunctionFlags{}, func(args []any) (any, error) {
		mu.Lock()
		calls++
		mu.Unlock()
		return args[0].(int64) + 1, nil
	}))
	var wg sync.WaitGroup
	results := make([]int64, 8)
	for i := range results {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			stmt, err := db.Prepare("select bump(?1)")
			if err != nil {
				t.Error(err)
				return
			}
			defer stmt.Close()
			if err := stmt.BindInt64(1, int64(i)); err != nil {
				t.Error(err)
				return
			}
			if _, err := stmt.Step(); err != nil {
				t.Error(err)
				return
			}
			results[i], _ = stmt.ColumnInt64(0)
		}(i)
	}
	wg.Wait()
	for i, value := range results {
		if value != int64(i+1) {
			t.Fatalf("results = %v", results)
		}
	}
	if calls != len(results) {
		t.Fatalf("calls = %d", calls)
	}
}
