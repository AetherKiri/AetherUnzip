#ifndef AETHER_UNZIP_ARCHIVE_H
#define AETHER_UNZIP_ARCHIVE_H
#include "io.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct au_context au_context;
typedef struct au_archive au_archive;
typedef uint32_t au_format;
enum {
    AU_FORMAT_UNKNOWN, AU_FORMAT_ZIP, AU_FORMAT_TAR, AU_FORMAT_7ZIP,
    AU_FORMAT_RAR, AU_FORMAT_RAR5, AU_FORMAT_GZIP, AU_FORMAT_LZ4, AU_FORMAT_ZSTD,
    AU_FORMAT_XZ, AU_FORMAT_BZIP2, AU_FORMAT_CAB, AU_FORMAT_ISO9660, AU_FORMAT_LHA,
    AU_FORMAT_BROTLI, AU_FORMAT_XP3
};
enum {
    AU_CAN_LIST = 1, AU_CAN_EXTRACT = 2, AU_CAN_READ = 4, AU_CAN_SEEK = 8,
    AU_REQUIRES_SEEKABLE_SOURCE = 16, AU_SUPPORTS_ENCRYPTION = 32,
    /* Accepts ordered volume sets via a concatenated source. */
    AU_SUPPORTS_MULTIVOLUME = 64
};
enum { AU_EVIDENCE_MAGIC = 1, AU_EVIDENCE_EXTENSION = 2, AU_EVIDENCE_STRUCTURE = 4 };
enum { AU_KIND_CONTAINER = 1, AU_KIND_STREAM = 2 };
enum { AU_ENTRY_FILE = 1, AU_ENTRY_DIRECTORY = 2, AU_ENTRY_OTHER = 3 };
enum { AU_CONFLICT_FAIL, AU_CONFLICT_SKIP, AU_CONFLICT_REPLACE, AU_CONFLICT_KEEP_BOTH };

typedef struct {
    uint32_t struct_size;
    uint32_t version;
    const char *id;
    uint32_t capabilities;
    uint32_t format_count;
    const au_format *formats;
} au_driver_info;

typedef struct {
    uint32_t struct_size;
    au_format candidate;
    au_format extension_hint;
    au_format format;
    au_format filter;
    uint32_t kind;
    uint32_t evidence;
    uint32_t capabilities;
    au_status validation;
} au_probe_result;

typedef struct {
    uint32_t struct_size;
    uint32_t kind;
    uint64_t index;
    uint64_t size;
    const char *name;
    size_t name_length;
    uint8_t size_known;
    uint8_t encrypted;
} au_entry;

typedef int32_t (*au_cancel_fn)(void *user);
typedef void (*au_progress_fn)(void *user, const au_entry *entry, uint64_t bytes_written,
                               uint64_t entry_bytes_written, uint64_t entries_done);
typedef struct {
    uint32_t struct_size;
    uint32_t conflict_policy;
    uint64_t max_entry_bytes;
    uint64_t max_total_bytes;
    uint64_t max_entries;
    uint32_t max_path_depth;
    uint32_t max_expansion_ratio;
    au_cancel_fn cancel;
    au_progress_fn progress;
    void *user;
} au_options;

au_status aether_unzip_context_create(au_context **out);
/* Copies a nonempty NUL-terminated UTF-8 passphrase. NULL creates a normal context. */
au_status aether_unzip_context_create_with_passphrase(const char *passphrase, au_context **out);
void aether_unzip_context_destroy(au_context *context);
size_t aether_unzip_driver_count(const au_context *context);
const au_driver_info *aether_unzip_driver_at(const au_context *context, size_t index);
/* Static UTF-8 display name. */
const char *aether_unzip_format_name(au_format format);
au_options aether_unzip_options_default(void);

/* Initialize result.struct_size before probing. A failed probe can still return evidence. */
au_status aether_unzip_probe(const au_context *context, au_source *source, const char *name_hint,
                             au_probe_result *result);
/* Copies options and name_hint and retains source. Callbacks and user data remain caller-owned. */
au_status aether_unzip_archive_open(const au_context *context, au_source *source,
                                    const char *name_hint, const au_options *options,
                                    au_archive **out);
/* Opens an entry catalog. Drivers may skip file data without decoding it.
 * Use a separate archive cursor for reading or verifying file contents. */
au_status aether_unzip_archive_open_catalog(const au_context *context, au_source *source,
                                            const char *name_hint, const au_options *options,
                                            au_archive **out);
const au_probe_result *aether_unzip_archive_info(const au_archive *archive);
/* Entry view is valid until next_entry or close. AU_END indicates enumeration is done. */
au_status aether_unzip_archive_next_entry(au_archive *archive, const au_entry **entry);
au_status aether_unzip_archive_read(au_archive *archive, void *buffer, size_t capacity,
                                    size_t *read_count);
void aether_unzip_archive_close(au_archive *archive);

/* Streams a ZIP of regular files and directories directly under directory. Names are
 * distinct UTF-8 basenames. Publishes the ZIP in directory without replacing anything.
 * Options apply the entry, byte, path-depth and cancellation limits; other fields are
 * ignored. Arguments are borrowed for the duration of the synchronous call. */
au_status aether_unzip_create_zip(const char *directory, const char *const *names, size_t count,
                                 const char *archive_name, const au_options *options);
/* Same ownership, limits and publication guarantees as create_zip. The output
 * suffix selects ZIP, TAR, TAR.GZ, TAR.ZST or standard unprotected XP3
 * (case-insensitive). XP3 stores files and needs at least one regular file. */
au_status aether_unzip_create_archive(const char *directory, const char *const *names, size_t count,
                                     const char *archive_name, const au_options *options);

/* Extract from a fresh cursor into an existing directory. NULL/0 selects all entries.
 * A non-NULL selection holds strictly increasing entry indexes. */
au_status aether_unzip_extract(const au_context *context, au_source *source, const char *name_hint,
                               const char *directory, const uint64_t *selection,
                               size_t selection_count, const au_options *options);

/* Validates a NUL-terminated entry path using the extraction rules. The returned
 * byte range borrows name; it need not be NUL terminated. AU_END is the root
 * directory marker and has no output path. */
au_status aether_unzip_normalize_entry_path(const char *name, uint32_t kind, uint32_t max_depth,
                                           const char **normalized, size_t *length);

/* Removes exactly one named, common directory component. NULL preserves paths.
 * Validates the selected paths before writing and skips the root directory marker.
 * The existing destination is treated as the new root. */
au_status aether_unzip_extract_stripping_root(const au_context *context, au_source *source,
                                             const char *name_hint, const char *directory,
                                             const uint64_t *selection, size_t selection_count,
                                             const char *root_component, const au_options *options);

#ifdef __cplusplus
}
#endif
#endif
