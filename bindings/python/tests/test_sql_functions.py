import gc

import pytest

import zova


def scalar(db, sql):
    statement = db.prepare(sql)
    try:
        assert statement.step() == zova.Step.ROW
        kind = statement.column_type(0)
        if kind == zova.ColumnType.INTEGER:
            return statement.column_int(0)
        if kind == zova.ColumnType.FLOAT:
            return statement.column_float(0)
        if kind == zova.ColumnType.TEXT:
            return statement.column_text(0)
        if kind == zova.ColumnType.BLOB:
            return statement.column_blob(0)
        return None
    finally:
        statement.close()


def test_functions_receive_and_return_every_sql_type():
    seen = []

    def echo(*args):
        seen.append(args)
        return args[0]

    with zova.Database.create_memory() as db:
        db.register_function("echo", -1, echo, deterministic=True)
        db.register_function("plus", 2, lambda a, b: a + b, innocuous=True)
        db.register_function("flag", 0, lambda: True, direct_only=True)
        db.register_function("raw", 0, lambda: bytearray(b"\x00\x01"))

        assert scalar(db, "select echo(42, 1.5, 'text', x'0001', null)") == 42
        assert seen[-1] == (42, 1.5, "text", b"\x00\x01", None)
        assert scalar(db, "select echo(2.5)") == 2.5
        assert scalar(db, "select echo('héllo')") == "héllo"
        assert scalar(db, "select echo(x'ff')") == b"\xff"
        assert scalar(db, "select echo(null)") is None
        assert scalar(db, "select plus(2, 3)") == 5
        assert scalar(db, "select plus('a', 'b')") == "ab"
        assert scalar(db, "select flag()") == 1
        assert scalar(db, "select raw()") == b"\x00\x01"


def test_exceptions_and_unsupported_results_fail_the_statement():
    def boom():
        raise RuntimeError("no luck")

    with zova.Database.create_memory() as db:
        db.register_function("boom", 0, boom)
        db.register_function("weird", 0, lambda: object())
        db.register_function("huge", 0, lambda: 1 << 70)
        for sql, message in [
            ("select boom()", "no luck"),
            ("select weird()", "unsupported SQL function result type object"),
            ("select huge()", "OverflowError"),
        ]:
            with pytest.raises(zova.ZovaError) as error:
                scalar(db, sql)
            assert message in str(error.value)
        # The connection stays usable.
        assert scalar(db, "select 1") == 1


def test_invalid_registrations_release_the_function():
    released = []

    class Tracked:
        def __call__(self):
            return 1

        def __del__(self):
            released.append(True)

    with zova.Database.create_memory() as db:
        for name, arity in [("zova_reserved", 0), ("", 0), ("ok", 200), ("bad name", 0)]:
            with pytest.raises((zova.ZovaError, ValueError)):
                db.register_function(name, arity, Tracked())
        gc.collect()
        assert len(released) == 4

        db.register_function("once", 0, Tracked())
        with pytest.raises(zova.ZovaError):
            db.register_function("once", 0, Tracked())
        gc.collect()
        assert len(released) == 5
        assert scalar(db, "select once()") == 1
    gc.collect()
    assert len(released) == 6
