import { Database } from "zova";

const db = Database.create("vectors-example.zova");
db.createVectorCollection("documents", {
  dimensions: 3,
  metric: "cosine",
  elementType: "f32",
});
db.putVectors("documents", [
  { id: "north", values: new Float32Array([1, 0, 0]) },
  { id: "east", values: new Float32Array([0, 1, 0]) },
]);
console.log(
  db.searchVectors("documents", new Float32Array([1, 0, 0]), {
    limit: 1,
  }),
);
db.close();
