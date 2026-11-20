#include "internal.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static const au_driver *const registered_drivers[] = {
    &au_xp3_driver, &au_libarchive_driver, &au_brotli_driver
};

struct au_context {
    atomic_uint refs;
    const au_driver *const *drivers;
    size_t count;
    char *passphrase;
};

uint32_t aether_unzip_abi_version(void) { return AETHER_UNZIP_ABI_VERSION; }
const char *aether_unzip_version(void) { return "0.1.0"; }

const char *aether_unzip_error_message(au_status status) {
    switch (status) {
    case AU_OK: return "Success";
    case AU_END: return "End of archive";
    case AU_INVALID: return "Invalid argument";
    case AU_IO: return "File or storage I/O failed";
    case AU_NOMEM: return "Out of memory";
    case AU_UNKNOWN_FORMAT: return "Archive format could not be identified";
    case AU_CORRUPT: return "Archive is incomplete, corrupt, or uses an unreadable encoding";
    case AU_UNSUPPORTED: return "Archive feature or entry type is unsupported";
    case AU_UNSAFE_PATH: return "Unsafe archive or destination path";
    case AU_LIMIT: return "Configured archive safety limit exceeded";
    case AU_CANCELLED: return "Operation cancelled";
    case AU_EXISTS: return "A destination item already exists";
    case AU_NOT_FOUND: return "Archive entry no longer exists";
    case AU_ENCRYPTED: return "This archive requires a password";
    case AU_BAD_PASSPHRASE: return "The password is incorrect or the encrypted data is damaged";
    case AU_UNSUPPORTED_ENCRYPTION: return "This archive uses an unsupported encryption method";
    case AU_PROFILE_MISMATCH: return "The file does not match the format profile";
    case AU_NO_SPACE: return "Not enough storage space";
    default: return "Unknown archive error";
    }
}

au_status aether_unzip_context_create(au_context **out) {
    return aether_unzip_context_create_with_passphrase(NULL, out);
}

au_status aether_unzip_context_create_with_passphrase(const char *passphrase, au_context **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (passphrase && (!*passphrase || !au_valid_utf8(passphrase))) return AU_INVALID;
    au_context *context = calloc(1, sizeof(*context));
    if (!context) return AU_NOMEM;
    atomic_init(&context->refs, 1);
    context->drivers = registered_drivers;
    context->count = sizeof(registered_drivers) / sizeof(registered_drivers[0]);
    if (passphrase) {
        context->passphrase = strdup(passphrase);
        if (!context->passphrase) {
            free(context);
            return AU_NOMEM;
        }
    }
    *out = context;
    return AU_OK;
}

void aether_unzip_context_destroy(au_context *context) {
    if (!context || atomic_fetch_sub_explicit(&context->refs, 1, memory_order_acq_rel) != 1) return;
    if (context->passphrase) {
        volatile unsigned char *bytes = (volatile unsigned char *)context->passphrase;
        size_t length = strlen(context->passphrase);
        while (length--) *bytes++ = 0;
        free(context->passphrase);
    }
    free(context);
}

void au_context_retain(const au_context *context) {
    atomic_fetch_add_explicit(&((au_context *)context)->refs, 1, memory_order_relaxed);
}

const char *au_context_passphrase(const au_context *context) { return context->passphrase; }
size_t aether_unzip_driver_count(const au_context *context) { return context ? context->count : 0; }
const au_driver *au_driver_at(const au_context *context, size_t index) {
    return index < aether_unzip_driver_count(context) ? context->drivers[index] : NULL;
}
const au_driver_info *aether_unzip_driver_at(const au_context *context, size_t index) {
    const au_driver *driver = au_driver_at(context, index);
    return driver ? &driver->info : NULL;
}

const char *aether_unzip_format_name(au_format format) {
    static const char *names[] = {"Unknown", "ZIP", "TAR", "7z", "RAR", "RAR5",
                                  "GZIP", "LZ4", "Zstandard", "XZ", "BZIP2", "CAB",
                                  "ISO 9660", "LHA / LZH", "Brotli", "XP3"};
    return format < sizeof(names) / sizeof(names[0]) ? names[format] : names[0];
}

au_options aether_unzip_options_default(void) {
    return (au_options){
        .struct_size = sizeof(au_options),
        .max_entry_bytes = UINT64_C(4) << 30,
        .max_total_bytes = UINT64_C(16) << 30,
        .max_entries = 10000,
        .max_path_depth = 32,
        .max_expansion_ratio = 1000
    };
}
uint64_t au_expansion_budget(const au_options *options, uint64_t source_length) {
    uint64_t ratio = options->max_expansion_ratio;
    if (source_length <= UINT64_MAX / ratio) {
        uint64_t budget = source_length * ratio;
        if (budget < options->max_total_bytes) return budget;
    }
    return options->max_total_bytes;
}

au_status au_options_resolve(const au_options *input, au_options *out) {
    *out = aether_unzip_options_default();
    if (!input) return AU_OK;
    if (input->struct_size < sizeof(*input) || input->conflict_policy > AU_CONFLICT_KEEP_BOTH ||
        !input->max_entry_bytes || !input->max_total_bytes || !input->max_entries ||
        !input->max_path_depth || !input->max_expansion_ratio) return AU_INVALID;
    *out = *input;
    return AU_OK;
}
int au_cancelled(const au_options *options) {
    return options->cancel && options->cancel(options->user);
}
