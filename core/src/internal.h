#ifndef AU_INTERNAL_H
#define AU_INTERNAL_H
#include "aetherunzip/api.h"
#include <sys/stat.h>

typedef struct au_driver {
    au_driver_info info;
    au_status (*probe)(au_source *, const char *, const char *, const au_options *,
                       au_probe_result *, void **);
    au_status (*next)(void *, au_entry *);
    au_status (*read)(void *, void *, size_t, size_t *);
    au_status (*skip)(void *, int catalog_only, int *skipped);
    void (*close)(void *);
} au_driver;

struct au_archive {
    const au_driver *driver;
    void *reader;
    au_probe_result info;
    au_entry entry;
    au_options options;
    uint64_t max_total;
    uint64_t entry_bytes;
    uint64_t total_bytes;
    uint64_t count;
    int active;
    int eof;
    int has_passphrase;
    int catalog_only;
    au_status failure;
};

extern const au_driver au_libarchive_driver;
extern const au_driver au_brotli_driver;
extern const au_driver au_xp3_driver;
const au_driver *au_driver_at(const au_context *context, size_t index);
const char *au_context_passphrase(const au_context *context);
void au_context_retain(const au_context *context);
void au_source_retain(au_source *source);
int au_source_uses_file(const au_source *source, const struct stat *file);
/* Takes ownership of fd on success. */
au_status au_source_from_fd(int fd, au_source **out);
size_t au_source_parts(const au_source *source);
void au_source_part_range(const au_source *source, size_t part, uint64_t *offset, uint64_t *length);
au_status au_options_resolve(const au_options *input, au_options *out);
uint64_t au_expansion_budget(const au_options *options, uint64_t source_length);
int au_cancelled(const au_options *options);
au_status au_archive_discard(au_archive *archive);
au_status au_archive_entry_access(const au_archive *archive);
int au_valid_utf8(const char *text);
au_status au_normalize_path(const char *path, uint32_t kind, uint32_t max_depth,
                            const char **name, size_t *length);
/* The returned parent is owned by the caller unless it is the borrowed root. */
au_status au_safe_parent(int root, const char *name, size_t length,
                         int *parent, char **leaf);
au_status au_write_all(int fd, const void *data, size_t size);
au_status au_output_error(int error);
int au_open_temp(int parent, const char *reserved, char *name, size_t capacity, int access);
#endif
