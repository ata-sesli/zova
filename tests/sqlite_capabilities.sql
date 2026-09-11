-- Runs through public SQL APIs in each binding. carray pointer binding is
-- covered separately by the native C probe (SQL alone cannot supply a pointer).
CREATE TEMP TABLE capability_check(ok INTEGER CHECK(ok = 1));
INSERT INTO capability_check VALUES
 (sqlite_compileoption_used('ENABLE_RTREE')),
 (sqlite_compileoption_used('ENABLE_GEOPOLY')),
 (sqlite_compileoption_used('ENABLE_CARRAY')),
 (sqlite_compileoption_used('ENABLE_MATH_FUNCTIONS')),
 (sqlite_compileoption_used('ENABLE_FTS5')),
 (sqlite_compileoption_used('ENABLE_DBSTAT_VTAB'));
CREATE VIRTUAL TABLE temp.capability_boxes USING rtree(id,x0,x1,y0,y1);
INSERT INTO capability_boxes VALUES(1,0,10,0,10);
CREATE VIRTUAL TABLE temp.capability_zones USING geopoly;
INSERT INTO capability_zones(_shape) VALUES('[[0,0],[10,0],[10,10],[0,10],[0,0]]');
INSERT INTO capability_check SELECT count(*) = 1 FROM capability_boxes WHERE x0 <= 5 AND x1 >= 5;
INSERT INTO capability_check SELECT count(*) = 1 FROM capability_zones WHERE geopoly_contains_point(_shape,5,5);
INSERT INTO capability_check VALUES(sqrt(81) = 9 AND pow(2,3) = 8 AND cos(0) = 1);
DROP TABLE capability_boxes;
DROP TABLE capability_zones;
DROP TABLE capability_check;
