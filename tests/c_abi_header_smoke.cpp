#include "zova.h"

#include <cstddef>
#include <cstdint>

static_assert(sizeof(zova_object_id) == 32, "object ids are fixed 32-byte SHA-256 values");
static_assert(sizeof(zova_object_chunk_id) == 32, "chunk ids are fixed 32-byte SHA-256 values");

int main() {
    zova_database *db = nullptr;
    zova_buffer buffer = {};
    zova_object_manifest manifest = {};
    zova_object_id id = {};

    zova_buffer_free(&buffer);
    zova_object_manifest_free(&manifest);

    return zova_database_close(db) == ZOVA_INVALID_ARGUMENT &&
                   zova_status_name(ZOVA_OK) != nullptr &&
                   zova_abi_version_string() != nullptr &&
                   id.bytes[0] == 0
               ? 0
               : 1;
}
