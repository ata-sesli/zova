use std::ffi::{c_char, c_int, c_void, CString};
use std::ptr;

extern "C" {
    fn sqlite3_open(name: *const c_char, db: *mut *mut c_void) -> c_int;
    fn sqlite3_close(db: *mut c_void) -> c_int;
    fn sqlite3_compileoption_used(name: *const c_char) -> c_int;
    fn sqlite3_prepare_v2(
        db: *mut c_void,
        sql: *const c_char,
        len: c_int,
        stmt: *mut *mut c_void,
        tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_step(stmt: *mut c_void) -> c_int;
    fn sqlite3_finalize(stmt: *mut c_void) -> c_int;
    fn sqlite3_column_int(stmt: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_carray_bind(
        stmt: *mut c_void,
        index: c_int,
        data: *mut c_void,
        count: c_int,
        flags: c_int,
        destroy: Option<unsafe extern "C" fn(*mut c_void)>,
    ) -> c_int;
}

#[test]
fn packaged_sqlite_modules_and_native_carray() {
    // Ensure the zova-sys native archive is linked in this test executable.
    unsafe {
        assert_eq!(zova_sys::zova_abi_version_major(), 1);
    }
    unsafe {
        for option in [
            "ENABLE_RTREE",
            "ENABLE_GEOPOLY",
            "ENABLE_CARRAY",
            "ENABLE_MATH_FUNCTIONS",
            "ENABLE_FTS5",
            "ENABLE_DBSTAT_VTAB",
        ] {
            assert_eq!(
                sqlite3_compileoption_used(CString::new(option).unwrap().as_ptr()),
                1,
                "{option}"
            );
        }
        let mut db = ptr::null_mut();
        assert_eq!(
            sqlite3_open(CString::new(":memory:").unwrap().as_ptr(), &mut db),
            0
        );
        for sql in [
            "CREATE VIRTUAL TABLE boxes USING rtree(id,x0,x1)",
            "INSERT INTO boxes VALUES(1,0,10)",
            "CREATE VIRTUAL TABLE zones USING geopoly",
            "INSERT INTO zones(_shape) VALUES('[[0,0],[10,0],[10,10],[0,10],[0,0]]')",
        ] {
            let mut stmt = ptr::null_mut();
            assert_eq!(
                sqlite3_prepare_v2(
                    db,
                    CString::new(sql).unwrap().as_ptr(),
                    -1,
                    &mut stmt,
                    ptr::null_mut()
                ),
                0
            );
            assert_eq!(sqlite3_step(stmt), 101);
            assert_eq!(sqlite3_finalize(stmt), 0);
        }
        let mut stmt = ptr::null_mut();
        let sql = CString::new("SELECT (SELECT sum(value) FROM carray(?)) + sqrt(81) + (SELECT count(*) FROM boxes WHERE x0<=5 AND x1>=5) + (SELECT count(*) FROM zones WHERE geopoly_contains_point(_shape,5,5))").unwrap();
        assert_eq!(
            sqlite3_prepare_v2(db, sql.as_ptr(), -1, &mut stmt, ptr::null_mut()),
            0
        );
        let mut values: [i32; 3] = [3, 7, 11];
        assert_eq!(
            sqlite3_carray_bind(stmt, 1, values.as_mut_ptr().cast(), 3, 0, None),
            0
        );
        assert_eq!(sqlite3_step(stmt), 100);
        assert_eq!(sqlite3_column_int(stmt, 0), 32);
        assert_eq!(sqlite3_finalize(stmt), 0);
        assert_eq!(sqlite3_close(db), 0);
    }
}
