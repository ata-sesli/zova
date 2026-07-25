import { Database } from "zova-db";

const db = Database.create("graphs-example.zova");
db.createGraph("knowledge");
db.putGraphNodes([
  {
    graphName: "knowledge",
    nodeId: "root",
    kind: "document",
    targetType: "none",
  },
  {
    graphName: "knowledge",
    nodeId: "child",
    kind: "section",
    targetType: "none",
  },
]);
db.putGraphEdges([
  {
    graphName: "knowledge",
    fromNodeId: "root",
    edgeType: "contains",
    toNodeId: "child",
  },
]);
console.log(
  db.graphWalk({
    graphName: "knowledge",
    startNodeId: "root",
    maxDepth: 2,
    limit: 100,
  }),
);
db.close();
