#ifndef AETHER_UNZIP_IO_H
#define AETHER_UNZIP_IO_H
#include "error.h"
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct au_source au_source;
typedef struct au_sink au_sink;
enum { AU_IO_SEQUENTIAL = 1, AU_IO_RANDOM = 2, AU_IO_LENGTH = 4 };

typedef struct {
    uint32_t struct_size;
    au_status (*read)(void *user, void *buffer, size_t capacity, size_t *read_count);
    au_status (*read_at)(void *user, uint64_t offset, void *buffer, size_t capacity,
                         size_t *read_count);
    void (*close)(void *user);
} au_source_callbacks;

typedef struct {
    uint32_t struct_size;
    au_status (*write)(void *user, const void *data, size_t size);
    au_status (*write_at)(void *user, uint64_t offset, const void *data, size_t size);
    au_status (*flush)(void *user);
    au_status (*close)(void *user);
} au_sink_callbacks;

/* Path arguments are NUL-terminated UTF-8. Memory sources copy input. */
au_status aether_unzip_source_file(const char *path, au_source **out);
au_status aether_unzip_source_memory(const void *data, size_t size, au_source **out);
/* Supply read, read_at, or both. On success, zero bytes means EOF. read_at must
 * leave sequential position unchanged. Copies callbacks and the optional length.
 * Close is called after the last reference to a successfully created source. */
au_status aether_unzip_source_callback(const au_source_callbacks *callbacks, void *user,
                                      const uint64_t *length, au_source **out);
au_status aether_unzip_source_slice(au_source *source, uint64_t offset, uint64_t length,
                                   au_source **out);
/* Presents the ordered sources as one byte sequence without copying their contents. */
au_status aether_unzip_source_concat(au_source *const *sources, size_t count, au_source **out);
void aether_unzip_source_close(au_source *source);
uint32_t aether_unzip_source_capabilities(const au_source *source);
au_status aether_unzip_source_length(const au_source *source, uint64_t *length);
au_status aether_unzip_source_read_at(const au_source *source, uint64_t offset, void *buffer,
                                     size_t capacity, size_t *read_count);
au_status aether_unzip_source_read(au_source *source, void *buffer, size_t capacity,
                                  size_t *read_count);

/* File sink creates a new file exclusively. Memory sink is bounded by limit. */
au_status aether_unzip_sink_file(const char *path, au_sink **out);
au_status aether_unzip_sink_memory(size_t limit, au_sink **out);
/* Supply write, write_at, or both. An AU_OK write accepts the complete block.
 * write_at must leave sequential position unchanged. Copies callbacks. */
au_status aether_unzip_sink_callback(const au_sink_callbacks *callbacks, void *user, au_sink **out);
uint32_t aether_unzip_sink_capabilities(const au_sink *sink);
au_status aether_unzip_sink_write(au_sink *sink, const void *data, size_t size);
au_status aether_unzip_sink_write_at(au_sink *sink, uint64_t offset, const void *data, size_t size);
au_status aether_unzip_sink_flush(au_sink *sink);
/* Memory view remains valid until mutation or close. */
au_status aether_unzip_sink_memory_view(const au_sink *sink, const void **data, size_t *size);
au_status aether_unzip_sink_close(au_sink *sink);

#ifdef __cplusplus
}
#endif
#endif
