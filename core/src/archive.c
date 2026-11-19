#include "internal.h"
#include <stdlib.h>

static au_status find_driver(const au_context *context, au_source *source, const char *hint,
                              const au_options *options, au_probe_result *info,
                              const au_driver **selected, void **reader) {
    *info = (au_probe_result){.struct_size = sizeof(*info), .validation = AU_UNKNOWN_FORMAT};
    if (au_cancelled(options)) return info->validation = AU_CANCELLED;
    uint32_t required = AU_IO_RANDOM | AU_IO_LENGTH;
    if ((aether_unzip_source_capabilities(source) & required) != required)
        return info->validation = AU_UNSUPPORTED;
    for (size_t index = 0; index < aether_unzip_driver_count(context); ++index) {
        const au_driver *driver = au_driver_at(context, index);
        au_status status = driver->probe(source, hint, au_context_passphrase(context), options,
                                        info, reader);
        info->validation = status;
        if (status == AU_OK) *selected = driver;
        if (status != AU_UNKNOWN_FORMAT) return status;
    }
    return AU_UNKNOWN_FORMAT;
}

au_status aether_unzip_probe(const au_context *context, au_source *source, const char *name_hint,
                             au_probe_result *result) {
    if (!context || !source || !result || result->struct_size < sizeof(*result)) return AU_INVALID;
    void *reader = NULL;
    const au_driver *driver = NULL;
    au_options options = aether_unzip_options_default();
    au_status status = find_driver(context, source, name_hint, &options, result, &driver, &reader);
    if (driver) driver->close(reader);
    return status;
}

au_status aether_unzip_archive_open(const au_context *context, au_source *source,
                                    const char *name_hint, const au_options *options,
                                    au_archive **out) {
    if (!context || !source || !out) return AU_INVALID;
    *out = NULL;
    au_options resolved;
    au_status status = au_options_resolve(options, &resolved);
    if (status != AU_OK) return status;
    au_archive *archive = calloc(1, sizeof(*archive));
    if (!archive) return AU_NOMEM;
    archive->options = resolved;
    archive->has_passphrase = au_context_passphrase(context) != NULL;
    archive->max_total = resolved.max_total_bytes;
    uint64_t bytes;
    if (aether_unzip_source_length(source, &bytes) == AU_OK &&
        bytes <= UINT64_MAX / resolved.max_expansion_ratio) {
        uint64_t budget = bytes * resolved.max_expansion_ratio;
        if (budget < archive->max_total) archive->max_total = budget;
    }
    status = find_driver(context, source, name_hint, &resolved, &archive->info,
                         &archive->driver, &archive->reader);
    if (status != AU_OK) {
        free(archive);
        return status;
    }
    *out = archive;
    return AU_OK;
}

const au_probe_result *aether_unzip_archive_info(const au_archive *archive) {
    return archive ? &archive->info : NULL;
}

au_status au_archive_entry_access(const au_archive *archive) {
    if (!archive->entry.encrypted) return AU_OK;
    if (!(archive->info.capabilities & AU_SUPPORTS_ENCRYPTION)) return AU_UNSUPPORTED_ENCRYPTION;
    return archive->has_passphrase ? AU_OK : AU_ENCRYPTED;
}

au_status aether_unzip_archive_read(au_archive *archive, void *buffer, size_t capacity,
                                    size_t *read_count) {
    if (!archive || !read_count || (!buffer && capacity) || !archive->active) return AU_INVALID;
    *read_count = 0;
    if (archive->failure) return archive->failure;
    if (au_cancelled(&archive->options)) return archive->failure = AU_CANCELLED;
    au_status status = au_archive_entry_access(archive);
    if (status != AU_OK) return archive->failure = status;
    if (!capacity || archive->eof) return AU_OK;
    if (capacity > 65536) capacity = 65536;
    size_t amount;
    status = archive->driver->read(archive->reader, buffer, capacity, &amount);
    if (status != AU_OK) return archive->failure = status;
    if (amount > archive->max_total - archive->total_bytes ||
        amount > archive->options.max_entry_bytes - archive->entry_bytes)
        return archive->failure = AU_LIMIT;
    archive->entry_bytes += amount;
    archive->total_bytes += amount;
    if (archive->entry.size_known && archive->entry.kind == AU_ENTRY_FILE &&
        (archive->entry_bytes > archive->entry.size ||
         (!amount && archive->entry_bytes != archive->entry.size)))
        return archive->failure = AU_CORRUPT;
    archive->eof = !amount;
    *read_count = amount;
    return AU_OK;
}

au_status au_archive_discard(au_archive *archive) {
    if (!archive->active || archive->eof) return AU_OK;
    int skipped;
    au_status status = archive->driver->skip(archive->reader, &skipped);
    if (status != AU_OK || skipped) return status;
    unsigned char buffer[16384];
    size_t amount;
    do { status = aether_unzip_archive_read(archive, buffer, sizeof(buffer), &amount); }
    while (status == AU_OK && amount);
    return status;
}

au_status aether_unzip_archive_next_entry(au_archive *archive, const au_entry **entry) {
    if (!archive || !entry) return AU_INVALID;
    *entry = NULL;
    if (archive->failure) return archive->failure;
    if (au_cancelled(&archive->options)) return archive->failure = AU_CANCELLED;
    au_status status = au_archive_discard(archive);
    if (status != AU_OK) return archive->failure = status;
    archive->active = 0;
    archive->eof = 0;
    archive->entry_bytes = 0;
    archive->entry = (au_entry){.struct_size = sizeof(au_entry), .index = archive->count};
    status = archive->driver->next(archive->reader, &archive->entry);
    if (status == AU_END) return AU_END;
    if (status != AU_OK) return archive->failure = status;
    if (archive->count >= archive->options.max_entries) return archive->failure = AU_LIMIT;
    ++archive->count;
    archive->active = 1;
    *entry = &archive->entry;
    return AU_OK;
}

void aether_unzip_archive_close(au_archive *archive) {
    if (!archive) return;
    archive->driver->close(archive->reader);
    free(archive);
}
