#ifndef AETHER_UNZIP_PROFILE_H
#define AETHER_UNZIP_PROFILE_H
#include "archive.h"
#ifdef __cplusplus
extern "C" {
#endif

#define AU_PROFILE_MAX_SIGNATURE 64u

typedef struct {
    uint32_t struct_size;
    au_format format;
    uint64_t signature_offset;
    const void *signature;
    size_t signature_size;
    uint64_t payload_offset;
    /* Zero uses all bytes from payload_offset to the end. */
    uint64_t payload_size;
    const char *name_hint;
} au_format_profile;

/* Compares the signature and returns a borrowed byte range backed by a retained
 * reference to source. Close the returned handle with source_close. */
au_status aether_unzip_profile_slice(au_source *source, const au_format_profile *profile,
                                    au_source **out);
/* Verifies the identified payload format and opens an archive. If requested, payload
 * receives a separately owned source for subsequent extraction or mounting. */
au_status aether_unzip_profile_open(const au_context *context, au_source *source,
    const au_format_profile *profile, const au_options *options, au_source **payload, au_archive **out);

#ifdef __cplusplus
}
#endif
#endif
