# C Scalar SQL Callback Examples

Zova v0.22 exposes scalar SQL function registration through the C ABI. These
callbacks run on Zova-owned SQLite connections opened through `zova_database`.

Callbacks must not re-enter the same `zova_database *`. Argument buffers are
borrowed for the callback only. Text, blob, and error result buffers only need
to stay valid until the callback returns because Zova copies them before SQLite
observes the result.

## Deterministic Scalar

```c
static void score_len(void *user_data,
                      const zova_sql_function_call *call,
                      zova_sql_result *out) {
    (void)user_data;
    if (call == NULL || call->argc != 1 ||
        call->argv[0].value_type != ZOVA_SQL_VALUE_TEXT) {
        out->result_type = ZOVA_SQL_RESULT_ERROR;
        out->error_message = "score_len expects text";
        out->error_message_len = strlen(out->error_message);
        return;
    }

    out->result_type = ZOVA_SQL_RESULT_INTEGER;
    out->int64_value = (int64_t)call->argv[0].data_len;
}

zova_database_register_function(&(zova_sql_function_register_request){
    .db = db,
    .name = "score_len",
    .arity = 1,
    .flags = ZOVA_SQL_FUNCTION_DETERMINISTIC |
             ZOVA_SQL_FUNCTION_INNOCUOUS,
    .callback = score_len,
});
```

## Text And Blob Arguments

```c
static void blob_prefix(void *user_data,
                        const zova_sql_function_call *call,
                        zova_sql_result *out) {
    (void)user_data;
    if (call == NULL || call->argc != 2 ||
        call->argv[0].value_type != ZOVA_SQL_VALUE_TEXT ||
        call->argv[1].value_type != ZOVA_SQL_VALUE_BLOB) {
        out->result_type = ZOVA_SQL_RESULT_ERROR;
        out->error_message = "blob_prefix expects text, blob";
        out->error_message_len = strlen(out->error_message);
        return;
    }

    const unsigned char *blob = (const unsigned char *)call->argv[1].data;
    const size_t len = call->argv[1].data_len < 4
        ? call->argv[1].data_len
        : 4;

    out->result_type = ZOVA_SQL_RESULT_BLOB;
    out->data = blob;
    out->data_len = len;
}
```

## Callback Errors

```c
static void app_fail(void *user_data,
                     const zova_sql_function_call *call,
                     zova_sql_result *out) {
    (void)user_data;
    (void)call;

    out->result_type = ZOVA_SQL_RESULT_ERROR;
    out->error_message = "application callback failed";
    out->error_message_len = strlen(out->error_message);
}
```

Executing `select app_fail()` returns a SQLite execution error on the Zova-owned
connection, and `zova_database_last_error_message(db)` includes the callback
message.
