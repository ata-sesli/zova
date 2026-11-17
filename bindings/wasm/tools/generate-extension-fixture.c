/* Records native extension results for the browser extension tests (#221):
 * bundled trgm SQL and lifecycle results, and a database with the repository's
 * C plugin fixture installed, opened natively without that plugin.
 *
 *   zig build c-abi --prefix <native>
 *   zig cc -std=c11 -Iinclude bindings/wasm/tools/generate-extension-fixture.c \
 *     tests/plugin_fixture.c <native>/lib/libzova_c.a -lpthread -o <generator>
 *   <generator> bindings/wasm/tests
 */
#include "zova.h"
#include "zova_plugin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const zova_plugin_descriptor_v1 *ZOVA_PLUGIN_CALL zova_plugin_entry_v1(uint32_t version);

static FILE *out;
static int first;

static void fail(const char *what, int status) {
    fprintf(stderr, "%s failed: %s\n", what, zova_status_name(status));
    exit(1);
}
static void json_string(const char *text, size_t len) {
    fputc('"', out);
    for (size_t index = 0; index < len; index++) {
        char c = text[index];
        if (c == '"' || c == '\\') fprintf(out, "\\%c", c);
        else if ((unsigned char)c < 0x20) fprintf(out, "\\u%04x", c);
        else fputc(c, out);
    }
    fputc('"', out);
}
/* One SQL statement whose rows are one text column: [sql, [rows...]]. */
static void query(zova_database *db, const char *sql) {
    zova_statement *statement = NULL;
    zova_database_prepare_request prepare = {db, sql, &statement};
    int status = zova_database_prepare(&prepare);
    if (status != ZOVA_OK) fail(sql, status);
    fprintf(out, "%s\n  [", first ? "" : ",");
    first = 0;
    json_string(sql, strlen(sql));
    fputs(", [", out);
    for (int row = 0;; row++) {
        zova_step_result result;
        zova_statement_step_request step = {statement, &result};
        if ((status = zova_statement_step(&step)) != ZOVA_OK) fail(sql, status);
        if (result != ZOVA_STEP_ROW) break;
        zova_text text = {0};
        zova_statement_column_text_request column = {statement, 0, &text};
        if ((status = zova_statement_column_text(&column)) != ZOVA_OK) fail(sql, status);
        if (row) fputs(", ", out);
        json_string(text.data, text.len);
        zova_text_free(&text);
    }
    fputs("]]", out);
    zova_statement_finalize(statement);
}
static void extension(const zova_extension_info *info) {
    fputs("{\"name\": ", out);
    json_string(info->name, info->name_len);
    fputs(", \"version\": ", out);
    json_string(info->version, info->version_len);
    fputs(", \"storagePrefix\": ", out);
    json_string(info->storage_prefix, info->storage_prefix_len);
    fputs(", \"zovaAbiMin\": ", out);
    json_string(info->zova_abi_min, info->zova_abi_min_len);
    fputs(", \"capabilities\": ", out);
    json_string(info->capabilities, info->capabilities_len);
    fprintf(out, ", \"required\": %s, \"manifestJson\": ", info->required ? "true" : "false");
    json_string(info->manifest_json, info->manifest_json_len);
    fputc('}', out);
}

static const char *trgm_sql[] = {
    "select quote(zova_trgm_similarity('attachment upload failed', 'attachement failed'))",
    "select quote(zova_trgm_similarity('', ''))",
    "select quote(zova_trgm_create_index('messages'))",
    "select quote(zova_trgm_put('messages', 'm1', 'record', 'messages', '1', 'attachment upload failed'))",
    "select quote(zova_trgm_put('messages', 'm2', 'record', 'messages', '2', 'payment declined'))",
    "select quote(zova_trgm_put('messages', 'm3', 'external', NULL, NULL, 'upload retry scheduled'))",
    "select quote(zova_trgm_put('messages', 'm4', 'record', 'messages', '4', 'attachment saved'))",
    "select quote(zova_trgm_delete('messages', 'm4'))",
    "select quote(document_id) || ',' || quote(target_type) || ',' || quote(target_namespace) || ',' || quote(target_ref) || ',' || quote(score) "
        "from zova_trgm_search where index_name = 'messages' and query = 'attachement failed' and threshold = 0.1 and \"limit\" = 10 order by rank",
    "select quote(document_id) || ',' || quote(score) from zova_trgm_search "
        "where index_name = 'messages' and query = 'uplod' and threshold = 0.05 and \"limit\" = 10 order by rank",
    "select quote(zova_trgm_drop_index('messages'))",
};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: generate-extension-fixture <output-directory>\n");
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof(path), "%s/extension-fixture.json", argv[1]);
    out = fopen(path, "w");
    if (!out) return 1;
    fprintf(out, "{\"generatedBy\": \"zova C ABI %s\",\n \"trgmSql\": [", zova_abi_version_string());

    zova_database *db = NULL;
    zova_message message = {0};
    zova_database_create_memory_request create = {&db, &message};
    int status = zova_database_create_memory(&create);
    if (status != ZOVA_OK) fail("create memory", status);
    zova_database_extension_request trgm = {db, "trgm"};
    if ((status = zova_database_extension_install(&trgm)) != ZOVA_OK) fail("install trgm", status);
    first = 1;
    for (size_t index = 0; index < sizeof(trgm_sql) / sizeof(trgm_sql[0]); index++) query(db, trgm_sql[index]);
    fputs("],\n \"installed\": [", out);
    zova_extension_list list = {0};
    zova_database_extension_list_request list_request = {db, &list};
    if ((status = zova_database_extension_list(&list_request)) != ZOVA_OK) fail("list", status);
    for (size_t index = 0; index < list.len; index++) {
        if (index) fputs(", ", out);
        extension(&list.items[index]);
    }
    zova_extension_list_free(&list);
    zova_database_simple_request simple = {db};
    fprintf(out, "],\n \"check\": \"%s\", \"checkAll\": \"%s\",", zova_status_name(zova_database_extension_check(&trgm)),
        zova_status_name(zova_database_extension_check_all(&simple)));
    fprintf(out, " \"installAgain\": \"%s\",", zova_status_name(zova_database_extension_install(&trgm)));
    zova_database_extension_request unknown = {db, "nonexistent"};
    fprintf(out, " \"installUnknown\": \"%s\",", zova_status_name(zova_database_extension_install(&unknown)));
    if ((status = zova_database_extension_drop(&trgm)) != ZOVA_OK) fail("drop trgm", status);
    fprintf(out, " \"checkAfterDrop\": \"%s\", \"dropAgain\": \"%s\",", zova_status_name(zova_database_extension_check(&trgm)),
        zova_status_name(zova_database_extension_drop(&trgm)));
    zova_database_close(db);

    /* A database with the C plugin fixture installed, then opened without it. */
    char missing[4096];
    snprintf(missing, sizeof(missing), "%s/extension-missing.zova", argv[1]);
    remove(missing);
    const zova_plugin_descriptor_v1 *plugins[] = {zova_plugin_entry_v1(ZOVA_PLUGIN_ABI_V1)};
    zova_database_open_plugins_request with_plugin = {0};
    with_plugin.path = missing;
    with_plugin.plugins = (const struct zova_plugin_descriptor_v1 *const *)plugins;
    with_plugin.plugin_count = 1;
    with_plugin.out_db = &db;
    with_plugin.out_error_message = &message;
    if ((status = zova_database_create_with_plugins(&with_plugin)) != ZOVA_OK) fail("create with plugin", status);
    zova_database_extension_request c_test = {db, "c_test"};
    if ((status = zova_database_extension_install(&c_test)) != ZOVA_OK) fail("install c_test", status);
    if ((status = zova_database_exec(&(zova_database_exec_request){db, "pragma journal_mode=delete"})) != ZOVA_OK) fail("journal mode", status);
    zova_database_close(db);
    db = NULL;
    zova_message_free(&message);
    zova_database_open_request open = {missing, &db, &message};
    status = zova_database_open(&open);
    fprintf(out, "\n \"missingPlugin\": {\"extension\": \"c_test\", \"status\": \"%s\", \"message\": ", zova_status_name(status));
    json_string(message.data ? message.data : "", message.data ? strlen(message.data) : 0);
    fputs("}}\n", out);
    if (db) zova_database_close(db);
    zova_message_free(&message);
    fclose(out);
    printf("wrote %s and %s\n", path, missing);
    return 0;
}
