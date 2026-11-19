#ifndef AETHER_UNZIP_RESOURCE_H
#define AETHER_UNZIP_RESOURCE_H
#include "archive.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Mount is the resource handle. Its directory and file entries share au_entry metadata. */
typedef struct au_resource_mount au_resource_mount;
typedef struct au_resource_file au_resource_file;
typedef struct au_resource_directory au_resource_directory;
typedef struct {
    uint32_t struct_size;
    au_resource_mount *mount;
    const char *prefix;
} au_resource_layer;
enum { AU_RESOURCE_STRICT, AU_RESOURCE_PREFER_LAST };
typedef struct {
    uint32_t struct_size;
    uint32_t max_depth;
    uint64_t max_staged_bytes;
} au_nested_limits;

au_status aether_unzip_resource_mount(const au_context *context, au_source *source,
                                      const char *name_hint, const au_options *options,
                                      au_resource_mount **out);
/* Combines indexed mounts under optional relative UTF-8 prefixes. Directories merge.
 * In strict mode duplicate files are ambiguous. Prefer-last selects the last layer's
 * regular file. File/directory conflicts remain ambiguous in either mode.
 * Options apply to the virtual index. Each archive retains its own read limits. */
au_status aether_unzip_resource_compose(const au_resource_layer *layers, size_t count,
    uint32_t collision_policy, size_t max_name_bytes, const au_options *options,
    au_resource_mount **out);
void aether_unzip_resource_unmount(au_resource_mount *mount);
const au_probe_result *aether_unzip_resource_info(const au_resource_mount *mount);
/* Retains the underlying source for the caller. Release it with source_close. */
au_status aether_unzip_resource_source(const au_resource_mount *mount, au_source **out);
au_status aether_unzip_resource_next(au_resource_mount *mount, const au_entry **entry);
/* Build once using a separate cursor. The name budget includes each NUL terminator.
 * Unsafe paths, links, special entries and root markers are omitted. */
au_status aether_unzip_resource_build_index(au_resource_mount *mount, size_t max_name_bytes);
/* Reports explicit index entries and their UTF-8 storage, including terminators. */
au_status aether_unzip_resource_index_size(const au_resource_mount *mount, size_t *entry_count,
                                           size_t *name_bytes);
/* Returns mount-owned metadata for an explicit, normalized UTF-8 path.
 * A duplicate path returns AU_EXISTS. An unindexed mount returns AU_UNSUPPORTED. */
au_status aether_unzip_resource_lookup(const au_resource_mount *mount, const char *path,
                                       const au_entry **entry);
/* Opens an indexed directory, including an implicit directory with children. Empty path
 * opens the root. The directory retains the mount until closed. */
au_status aether_unzip_resource_directory_open(au_resource_mount *mount, const char *path,
                                               au_resource_directory **out);
/* Enumerates immediate children. A synthesized directory has index UINT64_MAX.
 * Views are valid until the next call or close. AU_EXISTS advances past an ambiguous child. */
au_status aether_unzip_resource_directory_next(au_resource_directory *directory,
                                               const au_entry **entry);
void aether_unzip_resource_directory_close(au_resource_directory *directory);
/* Opens an independent sequential cursor. Query its metadata via resource_file_entry. */
au_status aether_unzip_resource_open(const au_resource_mount *mount, uint64_t index,
                                     au_resource_file **out);
au_status aether_unzip_resource_open_path(const au_resource_mount *mount, const char *path,
                                          au_resource_file **out);
/* Opens a file in an indexed parent as a new mount after staging it in a caller-owned
 * scratch directory. Limits apply across the ancestor chain. NULL child_context uses
 * the parent context. The new mount inherits the parent's archive options. */
au_status aether_unzip_resource_mount_nested(const au_resource_mount *parent, const char *path,
    const char *scratch_directory, const au_context *child_context, const au_nested_limits *limits,
    au_resource_mount **out);
const au_entry *aether_unzip_resource_file_entry(const au_resource_file *file);
uint32_t aether_unzip_resource_file_capabilities(const au_resource_file *file);
au_status aether_unzip_resource_read(au_resource_file *file, void *buffer, size_t capacity,
                                     size_t *read_count);
void aether_unzip_resource_close(au_resource_file *file);

#ifdef __cplusplus
}
#endif
#endif
