#include "zova.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void expect_status(zova_status actual, zova_status expected, const char *label) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s\n", label, zova_status_name(expected), zova_status_name(actual));
        exit(1);
    }
}

static void expect_bytes(const uint8_t *actual, const uint8_t *expected, size_t len, const char *label) {
    if (memcmp(actual, expected, len) != 0) {
        fprintf(stderr, "%s: byte mismatch\n", label);
        exit(1);
    }
}

static void expect_id_equal(zova_object_id left, zova_object_id right, const char *label) {
    if (memcmp(left.bytes, right.bytes, sizeof(left.bytes)) != 0) {
        fprintf(stderr, "%s: object id mismatch\n", label);
        exit(1);
    }
}

static void expect_chunk_id_equal(zova_object_chunk_id left, zova_object_chunk_id right, const char *label) {
    if (memcmp(left.bytes, right.bytes, sizeof(left.bytes)) != 0) {
        fprintf(stderr, "%s: chunk id mismatch\n", label);
        exit(1);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <db-path>\n", argv[0]);
        return 2;
    }

    const char *db_path = argv[1];
    remove(db_path);

    zova_database *db = NULL;
    zova_message open_message = {0};
    zova_database_open_request create_req = {
        .path = db_path,
        .out_db = &db,
        .out_error_message = &open_message,
    };
    expect_status(zova_database_create(&create_req), ZOVA_OK, "create database");
    zova_message_free(&open_message);

    zova_database_exec_request exec_req = {
        .db = db,
        .sql = "create table refs (id integer primary key, object_id blob not null)",
    };
    expect_status(zova_database_exec(&exec_req), ZOVA_OK, "exec sql");

    const uint8_t object_bytes[] = "hello from c abi";
    zova_object_id expected_id = {0};
    expect_status(zova_object_id_from_bytes(object_bytes, sizeof(object_bytes) - 1, &expected_id), ZOVA_OK, "object id");

    zova_object_id object_id = {0};
    zova_object_put_request put_req = {
        .db = db,
        .data = object_bytes,
        .len = sizeof(object_bytes) - 1,
        .out_id = &object_id,
    };
    expect_status(zova_object_put(&put_req), ZOVA_OK, "put object");
    expect_id_equal(object_id, expected_id, "put object id");

    uint8_t range[5] = {0};
    size_t copied = 0;
    zova_object_read_range_request range_req = {
        .db = db,
        .id = object_id,
        .offset = 6,
        .buffer = range,
        .buffer_len = sizeof(range),
        .out_copied = &copied,
    };
    expect_status(zova_object_read_range(&range_req), ZOVA_OK, "range read");
    if (copied != sizeof(range)) {
        fprintf(stderr, "range read: wrong copied length\n");
        return 1;
    }
    expect_bytes(range, (const uint8_t *)"from ", sizeof(range), "range read");

    zova_buffer full = {0};
    zova_object_get_request get_req = {
        .db = db,
        .id = object_id,
        .out_buffer = &full,
    };
    expect_status(zova_object_get(&get_req), ZOVA_OK, "get object");
    if (full.len != sizeof(object_bytes) - 1) {
        fprintf(stderr, "get object: wrong length\n");
        return 1;
    }
    expect_bytes(full.data, object_bytes, full.len, "get object");
    zova_buffer_free(&full);

    zova_object_manifest manifest = {0};
    zova_object_manifest_get_request manifest_req = {
        .db = db,
        .id = object_id,
        .out_manifest = &manifest,
    };
    expect_status(zova_object_manifest_get(&manifest_req), ZOVA_OK, "manifest");
    if (manifest.chunks_len != 1 || manifest.chunk_count != 1 || manifest.size_bytes != sizeof(object_bytes) - 1) {
        fprintf(stderr, "manifest: unexpected shape\n");
        return 1;
    }

    zova_buffer chunk = {0};
    zova_object_chunk_get_request chunk_get_req = {
        .db = db,
        .hash = manifest.chunks[0].hash,
        .out_buffer = &chunk,
    };
    expect_status(zova_object_chunk_get(&chunk_get_req), ZOVA_OK, "get chunk");
    expect_bytes(chunk.data, object_bytes, chunk.len, "get chunk");
    zova_buffer_free(&chunk);

    const uint8_t assembled_bytes[] = "left-right";
    const uint8_t left[] = "left-";
    const uint8_t right[] = "right";
    zova_object_id assembled_id = {0};
    zova_object_chunk_id left_hash = {0};
    zova_object_chunk_id right_hash = {0};
    expect_status(zova_object_id_from_bytes(assembled_bytes, sizeof(assembled_bytes) - 1, &assembled_id), ZOVA_OK, "assembled id");
    expect_status(zova_object_chunk_id_from_bytes(left, sizeof(left) - 1, &left_hash), ZOVA_OK, "left hash");
    expect_status(zova_object_chunk_id_from_bytes(right, sizeof(right) - 1, &right_hash), ZOVA_OK, "right hash");

    zova_object_chunk_put_request left_put = {
        .db = db,
        .expected_hash = left_hash,
        .data = left,
        .len = sizeof(left) - 1,
    };
    zova_object_chunk_put_request right_put = {
        .db = db,
        .expected_hash = right_hash,
        .data = right,
        .len = sizeof(right) - 1,
    };
    expect_status(zova_object_chunk_put(&left_put), ZOVA_OK, "put left chunk");
    expect_status(zova_object_chunk_put(&right_put), ZOVA_OK, "put right chunk");

    zova_object_manifest_chunk chunks[2] = {
        {.index = 0, .hash = left_hash, .offset = 0, .size_bytes = sizeof(left) - 1},
        {.index = 1, .hash = right_hash, .offset = sizeof(left) - 1, .size_bytes = sizeof(right) - 1},
    };
    zova_object_assemble_from_chunks_request assemble_req = {
        .db = db,
        .id = assembled_id,
        .size_bytes = sizeof(assembled_bytes) - 1,
        .chunks = chunks,
        .chunk_count = 2,
    };
    expect_status(zova_object_assemble_from_chunks(&assemble_req), ZOVA_OK, "assemble object");

    zova_object_writer *writer = NULL;
    zova_object_writer_create_request writer_create_req = {
        .db = db,
        .out_writer = &writer,
    };
    expect_status(zova_object_writer_create(&writer_create_req), ZOVA_OK, "writer create");
    zova_object_writer_write_request writer_write_1 = {
        .writer = writer,
        .data = (const uint8_t *)"streamed ",
        .len = 9,
    };
    zova_object_writer_write_request writer_write_2 = {
        .writer = writer,
        .data = (const uint8_t *)"object",
        .len = 6,
    };
    expect_status(zova_object_writer_write(&writer_write_1), ZOVA_OK, "writer write 1");
    expect_status(zova_object_writer_write(&writer_write_2), ZOVA_OK, "writer write 2");
    zova_object_id streamed_id = {0};
    zova_object_writer_finish_request writer_finish_req = {
        .writer = writer,
        .out_id = &streamed_id,
    };
    expect_status(zova_object_writer_finish(&writer_finish_req), ZOVA_OK, "writer finish");
    expect_status(zova_object_writer_destroy(writer), ZOVA_OK, "writer destroy");

    zova_object_delete_request missing_delete = {
        .db = db,
        .id = {{0}},
    };
    expect_status(zova_object_delete(&missing_delete), ZOVA_OBJECT_NOT_FOUND, "missing object");

    zova_object_manifest_free(&manifest);
    expect_status(zova_database_close(db), ZOVA_OK, "close database");

    db = NULL;
    zova_database_open_request open_req = {
        .path = db_path,
        .out_db = &db,
        .out_error_message = &open_message,
    };
    expect_status(zova_database_open(&open_req), ZOVA_OK, "reopen database");
    zova_message_free(&open_message);

    memset(range, 0, sizeof(range));
    copied = 0;
    range_req.db = db;
    expect_status(zova_object_read_range(&range_req), ZOVA_OK, "range read after reopen");
    if (copied != sizeof(range)) {
        fprintf(stderr, "range read after reopen: wrong copied length\n");
        return 1;
    }
    expect_bytes(range, (const uint8_t *)"from ", sizeof(range), "range read after reopen");

    expect_status(zova_database_close(db), ZOVA_OK, "close reopened database");
    return 0;
}
