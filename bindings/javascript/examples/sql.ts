import { Database } from "zova-db";

const db = Database.create("sql-example.zova");
db.exec("create table notes(id integer primary key, body text not null)");
db.transaction((transaction) => {
  transaction.exec("insert into notes(body) values ('hello')");
});
db.close();
