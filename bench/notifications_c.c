#define _POSIX_C_SOURCE 199309L

#include "zova.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define EVENTS 256
#define KV_BATCH 4096
#define WARMUPS 20
#define SAMPLES 100

static int cmp_f64(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static double median(double *values, size_t len) {
    qsort(values, len, sizeof(double), cmp_f64);
    return values[len / 2];
}

static double mad(double *values, size_t len, double med) {
    double *deviations = (double *)malloc(len * sizeof(double));
    for (size_t i = 0; i < len; i += 1) {
        deviations[i] = values[i] - med;
        if (deviations[i] < 0) deviations[i] = -deviations[i];
    }
    double result = median(deviations, len);
    free(deviations);
    return result;
}

static double p95(double *values, size_t len) {
    qsort(values, len, sizeof(double), cmp_f64);
    return values[(size_t)(len * 0.95)];
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void print_distribution(const char *label, double *samples) {
    double med = median(samples, SAMPLES);
    printf("%s median_ms=%.6f mad_ms=%.6f p95_ms=%.6f\n", label, med, mad(samples, SAMPLES, med), p95(samples, SAMPLES));
}

static void expect_ok(zova_status status, const char *label) {
    if (status != ZOVA_OK) {
        fprintf(stderr, "%s: expected OK, got %s\n", label, zova_status_name(status));
        exit(1);
    }
}

typedef void (*bench_body)(zova_database *, void *, const char *const *, size_t);

static void run_timed(const char *label, bench_body body, zova_database *db, void *sub_arg, const char *const *payloads) {
    double samples[SAMPLES];
    for (int i = 0; i < WARMUPS + SAMPLES; i += 1) {
        double start = now_ms();
        body(db, sub_arg, payloads, EVENTS);
        if (i >= WARMUPS) samples[i - WARMUPS] = now_ms() - start;
    }
    print_distribution(label, samples);
}

static void commit_no_notify(zova_database *db, void *sub_arg, const char *const *payloads, size_t count) {
    (void)sub_arg;
    (void)payloads;
    (void)count;
    expect_ok(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), "begin");
    expect_ok(zova_database_commit(&(zova_database_simple_request){.db = db}), "commit");
}

static void commit_one_notify(zova_database *db, void *sub_arg, const char *const *payloads, size_t count) {
    (void)count;
    zova_subscription *sub = (zova_subscription *)sub_arg;
    expect_ok(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), "begin");
    expect_ok(zova_database_notify(&(zova_database_notify_request){
                  .db = db,
                  .channel = "bench:one",
                  .payload = (const uint8_t *)payloads[0],
                  .payload_len = strlen(payloads[0]),
              }),
              "notify");
    expect_ok(zova_database_commit(&(zova_database_simple_request){.db = db}), "commit");
    zova_notification notification = {0};
    uint8_t has_notification = 0;
    expect_ok(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                  .subscription = sub,
                  .out_notification = &notification,
                  .out_has_notification = &has_notification,
              }),
              "receive");
    if (!has_notification) {
        fprintf(stderr, "commit_one_notify: expected notification\n");
        exit(1);
    }
    zova_notification_free(&notification);
}

static void commit_256_four_listeners(zova_database *db, void *sub_arg, const char *const *payloads, size_t count) {
    zova_subscription *const *subs = (zova_subscription *const *)sub_arg;
    expect_ok(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), "begin");
    for (size_t i = 0; i < count; i += 1) {
        expect_ok(zova_database_notify(&(zova_database_notify_request){
                      .db = db,
                      .channel = "bench:multi",
                      .payload = (const uint8_t *)payloads[i],
                      .payload_len = strlen(payloads[i]),
                  }),
                  "notify");
    }
    expect_ok(zova_database_commit(&(zova_database_simple_request){.db = db}), "commit");
    zova_notification notification = {0};
    uint8_t has_notification = 0;
    for (int i = 0; i < 4; i += 1) {
        for (size_t j = 0; j < count; j += 1) {
            expect_ok(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                          .subscription = subs[i],
                          .out_notification = &notification,
                          .out_has_notification = &has_notification,
                      }),
                      "receive");
            if (!has_notification) {
                fprintf(stderr, "commit_256: expected notification\n");
                exit(1);
            }
            zova_notification_free(&notification);
        }
    }
}

static void kv_batch_4096_commit_no_notify(zova_database *db, void *sub_arg, const char *const *payloads, size_t count) {
    (void)sub_arg;
    (void)payloads;
    (void)count;
    static uint8_t keys[KV_BATCH][8];
    static uint8_t value = 'v';
    static zova_kv_put_entry entries[KV_BATCH];
    for (int i = 0; i < KV_BATCH; i += 1) {
        int len = snprintf((char *)keys[i], sizeof(keys[i]), "k-%d", i);
        entries[i] = (zova_kv_put_entry){
            .key = {.data = keys[i], .len = (size_t)len},
            .value = {.data = &value, .len = 1},
        };
    }
    static const zova_kv_bytes ns = {.data = (const uint8_t *)"bench:kv", .len = 8};
    expect_ok(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), "begin");
    expect_ok(zova_kv_put_many(&(zova_kv_put_many_request){
                  .db = db,
                  .ns = ns,
                  .entries = entries,
                  .entries_len = KV_BATCH,
              }),
              "kv batch");
    expect_ok(zova_database_commit(&(zova_database_simple_request){.db = db}), "commit");
}

static void kv_batch_4096_commit_one_notify(zova_database *db, void *sub_arg, const char *const *payloads, size_t count) {
    zova_subscription *sub = (zova_subscription *)sub_arg;
    (void)payloads;
    (void)count;
    static uint8_t keys[KV_BATCH][8];
    static uint8_t value = 'v';
    static zova_kv_put_entry entries[KV_BATCH];
    for (int i = 0; i < KV_BATCH; i += 1) {
        int len = snprintf((char *)keys[i], sizeof(keys[i]), "k-%d", i);
        entries[i] = (zova_kv_put_entry){
            .key = {.data = keys[i], .len = (size_t)len},
            .value = {.data = &value, .len = 1},
        };
    }
    static const zova_kv_bytes ns = {.data = (const uint8_t *)"bench:kv", .len = 8};
    expect_ok(zova_database_begin_immediate(&(zova_database_simple_request){.db = db}), "begin");
    expect_ok(zova_kv_put_many(&(zova_kv_put_many_request){
                  .db = db,
                  .ns = ns,
                  .entries = entries,
                  .entries_len = KV_BATCH,
              }),
              "kv batch");
    expect_ok(zova_database_notify(&(zova_database_notify_request){
                  .db = db,
                  .channel = "cache:search-results",
                  .payload = (const uint8_t *)"generation:42",
                  .payload_len = 13,
              }),
              "notify");
    expect_ok(zova_database_commit(&(zova_database_simple_request){.db = db}), "commit");
    zova_notification notification = {0};
    uint8_t has_notification = 0;
    expect_ok(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                  .subscription = sub,
                  .out_notification = &notification,
                  .out_has_notification = &has_notification,
              }),
              "receive");
    if (!has_notification) {
        fprintf(stderr, "kv_batch aggregate: expected notification\n");
        exit(1);
    }
    zova_notification_free(&notification);
}

static void receive_256_prefilled(zova_database *db, void *sub_arg, const char *const *payloads, size_t count) {
    zova_subscription *sub = (zova_subscription *)sub_arg;
    (void)db;
    (void)count;
    static double samples[SAMPLES];
    static int sampled = 0;
    static int iteration = 0;
    for (size_t i = 0; i < count; i += 1) {
        expect_ok(zova_database_notify(&(zova_database_notify_request){
                      .db = db,
                      .channel = "bench:receive",
                      .payload = (const uint8_t *)payloads[i],
                      .payload_len = strlen(payloads[i]),
                  }),
                  "notify");
    }
    if (iteration >= WARMUPS) {
        double start = now_ms();
        zova_notification notification = {0};
        uint8_t has_notification = 0;
        for (size_t i = 0; i < count; i += 1) {
            expect_ok(zova_subscription_try_receive(&(zova_subscription_try_receive_request){
                          .subscription = sub,
                          .out_notification = &notification,
                          .out_has_notification = &has_notification,
                      }),
                      "receive");
            if (!has_notification) {
                fprintf(stderr, "receive_256: expected notification\n");
                exit(1);
            }
            zova_notification_free(&notification);
        }
        samples[sampled] = now_ms() - start;
        sampled += 1;
    }
    iteration += 1;
    if (sampled == SAMPLES) {
        print_distribution("receive_256_prefilled", samples);
        sampled = -1;
    }
}

int main(void) {
    zova_database *db = NULL;
    expect_ok(zova_database_create_memory(&(zova_database_create_memory_request){
                  .out_db = &db,
                  .out_error_message = NULL,
              }),
              "create memory");

    const char *payloads[EVENTS];
    for (size_t i = 0; i < EVENTS; i += 1) {
        static char buffer[EVENTS][16];
        snprintf(buffer[i], sizeof(buffer[i]), "event-%zu", i);
        payloads[i] = buffer[i];
    }

    run_timed("commit_no_notify", commit_no_notify, db, NULL, payloads);

    zova_subscription *one_sub = NULL;
    expect_ok(zova_database_listen(&(zova_database_listen_request){
                  .db = db,
                  .channel = "bench:one",
                  .out_subscription = &one_sub,
              }),
              "listen one");
    run_timed("commit_one_notify", commit_one_notify, db, one_sub, payloads);

    zova_subscription *multi_subs[4];
    for (int i = 0; i < 4; i += 1) {
        expect_ok(zova_database_listen(&(zova_database_listen_request){
                      .db = db,
                      .channel = "bench:multi",
                      .out_subscription = &multi_subs[i],
                  }),
                  "listen multi");
    }
    {
        double samples[SAMPLES];
        for (int i = 0; i < WARMUPS + SAMPLES; i += 1) {
            double start = now_ms();
            commit_256_four_listeners(db, multi_subs, payloads, EVENTS);
            if (i >= WARMUPS) samples[i - WARMUPS] = now_ms() - start;
        }
        print_distribution("commit_256_four_listeners", samples);
    }

    run_timed("kv_batch_4096_commit_no_notify", kv_batch_4096_commit_no_notify, db, NULL, payloads);

    zova_subscription *agg_sub = NULL;
    expect_ok(zova_database_listen(&(zova_database_listen_request){
                  .db = db,
                  .channel = "cache:search-results",
                  .out_subscription = &agg_sub,
              }),
              "listen aggregate");
    run_timed("kv_batch_4096_commit_one_notify", kv_batch_4096_commit_one_notify, db, agg_sub, payloads);

    zova_subscription *receive_sub = NULL;
    expect_ok(zova_database_listen(&(zova_database_listen_request){
                  .db = db,
                  .channel = "bench:receive",
                  .out_subscription = &receive_sub,
              }),
              "listen receive");
    for (int i = 0; i < WARMUPS + SAMPLES; i += 1) {
        receive_256_prefilled(db, receive_sub, payloads, EVENTS);
    }

    expect_ok(zova_subscription_close(one_sub), "close one");
    for (int i = 0; i < 4; i += 1) {
        expect_ok(zova_subscription_close(multi_subs[i]), "close multi");
    }
    expect_ok(zova_subscription_close(agg_sub), "close aggregate");
    expect_ok(zova_subscription_close(receive_sub), "close receive");
    expect_ok(zova_database_close(db), "close db");
    return 0;
}