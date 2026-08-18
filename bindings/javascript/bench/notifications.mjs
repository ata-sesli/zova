import { Database } from "../js/index.js";

const events = 256;
const kvEntries = 4096;
const warmups = 20;
const samples = 100;

function nowMs() {
  return performance.now();
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function mad(values, med) {
  return median(values.map((v) => Math.abs(v - med)));
}

function p95(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
}

function report(label, samplesMs) {
  const med = median(samplesMs);
  console.log(
    `${label} median_ms=${med.toFixed(6)} mad_ms=${mad(samplesMs, med).toFixed(6)} p95_ms=${p95(samplesMs).toFixed(6)}`,
  );
}

function run(label, warmups, samples, fn) {
  const measured = [];
  for (let i = 0; i < warmups + samples; i += 1) {
    const start = nowMs();
    fn();
    if (i >= warmups) measured.push(nowMs() - start);
  }
  report(label, measured);
}

const db = Database.createMemory();
try {
  const payloads = Array.from({ length: events }, (_, i) => `event-${i}`);

  run("commit_no_notify", warmups, samples, () => {
    db.beginImmediate();
    db.commit();
  });

  run("commit_one_notify", warmups, samples, () => {
    const sub = db.listen("bench:one");
    db.beginImmediate();
    db.notify("bench:one", payloads[0]);
    db.commit();
    sub.tryReceive();
    sub.close();
  });

  const multi = Array.from({ length: 4 }, () => db.listen("bench:multi"));
  run("commit_256_four_listeners", warmups, samples, () => {
    db.beginImmediate();
    for (const payload of payloads) db.notify("bench:multi", payload);
    db.commit();
    for (const sub of multi) {
      for (let i = 0; i < events; i += 1) sub.tryReceive();
    }
  });
  for (const sub of multi) sub.close();

  const kvBatch = Array.from({ length: kvEntries }, (_, i) => ({
    key: Buffer.from(`k-${i}`),
    value: Buffer.from("v"),
  }));
  const kvNamespace = Buffer.from("bench:kv");

  run("kv_batch_4096_commit_no_notify", warmups, samples, () => {
    db.beginImmediate();
    db.kvPutMany(kvNamespace, kvBatch);
    db.commit();
  });

  const aggSub = db.listen("cache:search-results");
  run("kv_batch_4096_commit_one_notify", warmups, samples, () => {
    db.beginImmediate();
    db.kvPutMany(kvNamespace, kvBatch);
    db.notify("cache:search-results", "generation:42");
    db.commit();
    aggSub.tryReceive();
  });
  aggSub.close();

  const receiveSub = db.listen("bench:receive");
  run("notify_256_receive_all", warmups, samples, () => {
    for (const payload of payloads) db.notify("bench:receive", payload);
    for (let i = 0; i < events; i += 1) receiveSub.tryReceive();
  });
  receiveSub.close();
} finally {
  db.close();
}