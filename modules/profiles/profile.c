#include "internal.h"
#include <string.h>

au_status aether_unzip_profile_slice(au_source *source, const au_format_profile *profile,
                                    au_source **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!source || !profile || profile->struct_size < sizeof(*profile) ||
        profile->format <= AU_FORMAT_UNKNOWN || profile->format > AU_FORMAT_XP3 ||
        !profile->signature || !profile->signature_size ||
        profile->signature_size > AU_PROFILE_MAX_SIGNATURE ||
        (profile->name_hint && !au_valid_utf8(profile->name_hint))) return AU_INVALID;
    uint64_t length;
    au_status status = aether_unzip_source_length(source, &length);
    if (status != AU_OK) return status;
    if (!(aether_unzip_source_capabilities(source) & AU_IO_RANDOM)) return AU_UNSUPPORTED;
    if (profile->signature_offset > length || profile->signature_size > length - profile->signature_offset ||
        profile->payload_offset >= length || profile->payload_size > length - profile->payload_offset)
        return AU_PROFILE_MISMATCH;
    uint8_t bytes[AU_PROFILE_MAX_SIGNATURE];
    size_t offset = 0;
    while (offset < profile->signature_size) {
        size_t count;
        status = aether_unzip_source_read_at(source, profile->signature_offset + offset,
                                          bytes + offset, profile->signature_size - offset, &count);
        if (status != AU_OK) return status;
        if (!count) return AU_IO;
        offset += count;
    }
    if (memcmp(bytes, profile->signature, profile->signature_size)) return AU_PROFILE_MISMATCH;
    uint64_t size = profile->payload_size ? profile->payload_size : length - profile->payload_offset;
    return aether_unzip_source_slice(source, profile->payload_offset, size, out);
}

au_status aether_unzip_profile_open(const au_context *context, au_source *source,
    const au_format_profile *profile, const au_options *options, au_source **payload, au_archive **out) {
    if (payload) *payload = NULL;
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!context) return AU_INVALID;
    au_options resolved;
    au_status status = au_options_resolve(options, &resolved);
    if (status != AU_OK) return status;
    if (au_cancelled(&resolved)) return AU_CANCELLED;

    au_source *slice = NULL;
    status = aether_unzip_profile_slice(source, profile, &slice);
    if (status != AU_OK) return status;
    au_archive *archive = NULL;
    status = aether_unzip_archive_open(context, slice, profile->name_hint, &resolved, &archive);
    if (status == AU_OK && aether_unzip_archive_info(archive)->format != profile->format)
        status = AU_PROFILE_MISMATCH;
    if (status != AU_OK) aether_unzip_archive_close(archive);
    else *out = archive;
    if (status == AU_OK && payload) *payload = slice;
    else aether_unzip_source_close(slice);
    return status;
}
