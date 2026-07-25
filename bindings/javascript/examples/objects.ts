import { Database, objectIdToHex } from "zova-js";

const db = Database.create("objects-example.zova");
const id = db.putObject(new TextEncoder().encode("content-addressed bytes"));
console.log(objectIdToHex(id), new TextDecoder().decode(db.getObject(id)));
db.close();
