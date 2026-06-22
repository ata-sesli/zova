import zova


with zova.Database.create("python-basic.zova") as db:
    db.exec("create table notes(id integer primary key, body text not null)")
    with db.prepare("insert into notes(body) values (?1)") as stmt:
        stmt.bind_text(1, "hello from Python")
        assert stmt.step() == zova.Step.DONE

    with db.prepare("select body from notes where id = ?1") as stmt:
        stmt.bind_int(1, 1)
        assert stmt.step() == zova.Step.ROW
        print(stmt.column_text(0))
