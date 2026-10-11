#include "zova.h"
#include <stdio.h>
#include <stdlib.h>

static zova_message message = {0};
static void expect(zova_status actual, zova_status expected, const char *operation) {
    if (actual != expected) {
        fprintf(stderr, "%s: expected %s, got %s: %.*s\n", operation,
            zova_status_name(expected), zova_status_name(actual),
            (int)message.len, message.data ? message.data : "");
        zova_message_free(&message);
        exit(1);
    }
    zova_message_free(&message);
}

/* Exercise the shipped C ABI against a real C/C++ bundle. The caller owns an
 * isolated bundle, database path and trust store; no user's default trust is changed. */
int main(int argc, char **argv) {
    zova_database *db = NULL;
    zova_statement *statement = NULL;
    zova_step_result step;
    int64_t value;
    zova_extension_bundle_request bundle;
    zova_database_open_extensions_request open;
    zova_database_extension_request install;
    zova_database_prepare_request prepare;
    zova_database_open_request plain;
    const char *paths[1];
    if (argc != 4 && argc != 5) return 2;
    paths[0] = argv[1];
    bundle = (zova_extension_bundle_request){argv[1], argv[3], &message};
    open = (zova_database_open_extensions_request){argv[2], 0, 0, paths, 1, argv[3], &db, &message};
    if (argc == 5) {
        if (argv[4][0] == 'i') {
            expect(zova_extension_bundle_verify(&bundle), ZOVA_EXTENSION_INCOMPATIBLE, "incompatible descriptor");
        } else if (argv[4][0] == 'v') {
            expect(zova_extension_bundle_verify(&bundle), ZOVA_EXTENSION_UNAVAILABLE, "missing dependency");
        } else {
            expect(zova_database_create_with_extensions(&open), ZOVA_EXTENSION_UNAVAILABLE, "changed or missing bundle");
            if (db != NULL) return 3;
        }
        return 0;
    }
    expect(zova_extension_bundle_verify(&bundle), ZOVA_OK, "verify portable bundle");
    expect(zova_database_create_with_extensions(&open), ZOVA_EXTENSION_UNAVAILABLE, "untrusted create");
    if (db != NULL) return 3;
    expect(zova_extension_bundle_trust(&bundle), ZOVA_OK, "trust portable bundle");
    expect(zova_database_create_with_extensions(&open), ZOVA_OK, "trusted create");
    install = (zova_database_extension_request){db, "c_test"};
    expect(zova_database_extension_install(&install), ZOVA_OK, "install");
    prepare = (zova_database_prepare_request){db, "SELECT zova_c_test_cached()", &statement};
    expect(zova_database_prepare(&prepare), ZOVA_OK, "prepare plugin operation");
    expect(zova_statement_step(&(zova_statement_step_request){statement, &step}), ZOVA_OK, "execute plugin operation");
    expect(zova_statement_column_int64(&(zova_statement_column_int64_request){statement, 0, &value}), ZOVA_OK, "read plugin result");
    if (step != ZOVA_STEP_ROW || value != 42) return 4;
    expect(zova_database_close(db), ZOVA_MISUSE, "close with live callback statement");
    expect(zova_statement_finalize(statement), ZOVA_OK, "finalize plugin statement");
    expect(zova_database_close(db), ZOVA_OK, "close and cleanup");
    db = NULL;
    plain = (zova_database_open_request){argv[2], &db, &message};
    expect(zova_database_open(&plain), ZOVA_EXTENSION_UNAVAILABLE, "metadata must not load code");
    if (db != NULL) return 5;
    open.flags = ZOVA_OPEN_READ_ONLY;
    expect(zova_database_open_with_extensions(&open), ZOVA_OK, "read-only reopen");
    install.db = db;
    expect(zova_database_extension_check(&install), ZOVA_OK, "check recovered registration");
    expect(zova_database_close(db), ZOVA_OK, "read-only close");
    puts("portable package plugin smoke: ok");
    return 0;
}
