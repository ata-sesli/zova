package zova

import "testing"

// leaveFreePages leaves about 300 free pages in the main database.
func leaveFreePages(t *testing.T, db *DB) {
	t.Helper()
	must(t, db.Exec("create table scratch(data blob); "+
		"with recursive n(i) as (select 1 union all select i + 1 from n where i < 300) "+
		"insert into scratch select zeroblob(4000) from n; "+
		"drop table scratch"))
}

func TestReclaimSpaceReleasesFreePagesInBoundedSteps(t *testing.T) {
	db, err := Create(tempZovaPath(t, "reclaim"))
	must(t, err)
	defer db.Close()
	leaveFreePages(t, db)

	bounded, err := db.ReclaimSpace(ReclaimOptions{MaxPages: 100, StepPages: 30})
	must(t, err)
	if len(bounded) != 1 {
		t.Fatalf("bounded reclaim: got %d members", len(bounded))
	}
	first := bounded[0]
	if first.Member != ProgressMemberMain || first.AutoVacuum != AutoVacuumIncremental ||
		first.PageSize != 4096 || first.PagesReleased != 100 || first.FreePagesLeft == 0 {
		t.Fatalf("bounded reclaim: got %+v", first)
	}

	rest, err := db.ReclaimSpace()
	must(t, err)
	if rest[0].PagesReleased != first.FreePagesLeft || rest[0].FreePagesLeft != 0 {
		t.Fatalf("full reclaim: got %+v", rest[0])
	}

	must(t, db.Begin())
	if _, err := db.ReclaimSpace(); !errorStatusIs(err, StatusObjectTransactionActive) {
		t.Fatalf("reclaim in transaction: got %v", err)
	}
	must(t, db.Rollback())

	if _, err := db.ReclaimSpace(ReclaimOptions{}, ReclaimOptions{}); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("two options values: got %v", err)
	}
}

func TestReclaimSpaceReportsNoneMode(t *testing.T) {
	db, err := Create(tempZovaPath(t, "reclaim-none"))
	must(t, err)
	defer db.Close()
	must(t, db.Exec("pragma auto_vacuum = none; vacuum"))
	leaveFreePages(t, db)

	members, err := db.ReclaimSpace()
	must(t, err)
	if len(members) != 1 || members[0].AutoVacuum != AutoVacuumNone ||
		members[0].PagesReleased != 0 || members[0].FreePagesLeft == 0 {
		t.Fatalf("none-mode reclaim: got %+v", members)
	}
}
