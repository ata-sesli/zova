use std::time::Instant;

use zova::{Database, KvEntry};

const EVENTS: usize = 256;
const KV_BATCH: usize = 4096;
const WARMUPS: usize = 20;
const SAMPLES: usize = 100;

fn median(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    sorted[sorted.len() / 2]
}

fn mad(values: &[f64], med: f64) -> f64 {
    let deviations: Vec<f64> = values.iter().map(|v| (v - med).abs()).collect();
    median(&deviations)
}

fn p95(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    sorted[(sorted.len() as f64 * 0.95) as usize]
}

fn report(label: &str, samples: &[f64]) {
    let med = median(samples);
    println!(
        "{label} median_ms={med:.6} mad_ms={:.6} p95_ms={:.6}",
        mad(samples, med),
        p95(samples)
    );
}

fn main() {
    println!(
        "rust={} events_per_iteration={EVENTS} kv_batch_entries={KV_BATCH}",
        env!("CARGO_PKG_VERSION")
    );

    let mut db = Database::create_memory().unwrap();
    let payloads: Vec<String> = (0..EVENTS).map(|i| format!("event-{i}")).collect();
    let mut samples = [0.0f64; SAMPLES];

    for i in 0..WARMUPS + SAMPLES {
        let start = Instant::now();
        db.begin_immediate().unwrap();
        db.commit().unwrap();
        if i >= WARMUPS {
            samples[i - WARMUPS] = start.elapsed().as_secs_f64() * 1000.0;
        }
    }
    report("commit_no_notify", &samples);

    let mut one_sub = db.listen("bench:one").unwrap();
    for i in 0..WARMUPS + SAMPLES {
        let start = Instant::now();
        db.begin_immediate().unwrap();
        db.notify("bench:one", &payloads[0]).unwrap();
        db.commit().unwrap();
        one_sub.try_receive().unwrap().unwrap();
        if i >= WARMUPS {
            samples[i - WARMUPS] = start.elapsed().as_secs_f64() * 1000.0;
        }
    }
    report("commit_one_notify", &samples);

    let mut multi_subs = Vec::new();
    for _ in 0..4 {
        multi_subs.push(db.listen("bench:multi").unwrap());
    }
    for i in 0..WARMUPS + SAMPLES {
        let start = Instant::now();
        db.begin_immediate().unwrap();
        for payload in &payloads {
            db.notify("bench:multi", payload).unwrap();
        }
        db.commit().unwrap();
        for sub in &mut multi_subs {
            for _ in 0..EVENTS {
                sub.try_receive().unwrap().unwrap();
            }
        }
        if i >= WARMUPS {
            samples[i - WARMUPS] = start.elapsed().as_secs_f64() * 1000.0;
        }
    }
    report("commit_256_four_listeners", &samples);

    let kv_keys: Vec<Vec<u8>> = (0..KV_BATCH)
        .map(|i| format!("k-{i}").into_bytes())
        .collect();
    let kv_value: Vec<u8> = b"v".to_vec();
    let entries: Vec<KvEntry> = kv_keys
        .iter()
        .map(|key| KvEntry {
            key: key.as_slice(),
            value: kv_value.as_slice(),
        })
        .collect();
    for i in 0..WARMUPS + SAMPLES {
        let start = Instant::now();
        db.begin_immediate().unwrap();
        db.kv_put_many(b"bench:kv", &entries).unwrap();
        db.commit().unwrap();
        if i >= WARMUPS {
            samples[i - WARMUPS] = start.elapsed().as_secs_f64() * 1000.0;
        }
    }
    report("kv_batch_4096_commit_no_notify", &samples);

    let mut agg_sub = db.listen("cache:search-results").unwrap();
    for i in 0..WARMUPS + SAMPLES {
        let start = Instant::now();
        db.begin_immediate().unwrap();
        db.kv_put_many(b"bench:kv", &entries).unwrap();
        db.notify("cache:search-results", "generation:42").unwrap();
        db.commit().unwrap();
        agg_sub.try_receive().unwrap().unwrap();
        if i >= WARMUPS {
            samples[i - WARMUPS] = start.elapsed().as_secs_f64() * 1000.0;
        }
    }
    report("kv_batch_4096_commit_one_notify", &samples);

    let mut receive_sub = db.listen("bench:receive").unwrap();
    for i in 0..WARMUPS + SAMPLES {
        for payload in &payloads {
            db.notify("bench:receive", payload).unwrap();
        }
        let start = Instant::now();
        for _ in 0..EVENTS {
            receive_sub.try_receive().unwrap().unwrap();
        }
        if i >= WARMUPS {
            samples[i - WARMUPS] = start.elapsed().as_secs_f64() * 1000.0;
        }
    }
    report("receive_256_prefilled", &samples);
}
