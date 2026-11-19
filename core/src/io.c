#include "internal.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    au_source *source;
    uint64_t start;
} au_segment;

struct au_source {
    atomic_uint refs;
    uint64_t length, cursor, offset;
    au_source *parent;
    unsigned char *data;
    au_segment *segments;
    size_t segment_count;
    au_source_callbacks callbacks;
    void *user;
    uint32_t capabilities;
    int fd;
};
struct au_sink {
    uint64_t cursor;
    size_t length, capacity, limit;
    unsigned char *data;
    au_sink_callbacks callbacks;
    void *user;
    int fd;
};

static const uint32_t ranged_source = AU_IO_RANDOM | AU_IO_LENGTH;

static au_source *new_source(au_source **out, uint64_t length) {
    *out = calloc(1, sizeof(**out));
    if (*out) {
        atomic_init(&(*out)->refs, 1);
        (*out)->fd = -1;
        (*out)->length = length;
        (*out)->capabilities = AU_IO_SEQUENTIAL | ranged_source;
    }
    return *out;
}

au_status au_source_from_fd(int fd, au_source **out) {
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0) return AU_IO;
    au_source *source = new_source(out, (uint64_t)st.st_size);
    if (!source) return AU_NOMEM;
    source->fd = fd;
    return AU_OK;
}

au_status aether_unzip_source_file(const char *path, au_source **out) {
    if (!out || !path) return AU_INVALID;
    *out = NULL;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return AU_IO;
    au_status status = au_source_from_fd(fd, out);
    if (status != AU_OK) close(fd);
    return status;
}

au_status aether_unzip_source_memory(const void *data, size_t size, au_source **out) {
    if (!out || (!data && size)) return AU_INVALID;
    au_source *source = new_source(out, size);
    if (!source) return AU_NOMEM;
    if (size) {
        source->data = malloc(size);
        if (!source->data) {
            aether_unzip_source_close(source);
            *out = NULL;
            return AU_NOMEM;
        }
        memcpy(source->data, data, size);
    }
    return AU_OK;
}

au_status aether_unzip_source_callback(const au_source_callbacks *callbacks, void *user,
                                      const uint64_t *length, au_source **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!callbacks || callbacks->struct_size < sizeof(*callbacks) ||
        (!callbacks->read && !callbacks->read_at)) return AU_INVALID;
    au_source *source = new_source(out, length ? *length : 0);
    if (!source) return AU_NOMEM;
    source->callbacks = *callbacks;
    source->user = user;
    source->capabilities = AU_IO_SEQUENTIAL;
    if (callbacks->read_at) source->capabilities |= AU_IO_RANDOM;
    if (length) source->capabilities |= AU_IO_LENGTH;
    return AU_OK;
}

au_status aether_unzip_source_slice(au_source *source, uint64_t offset, uint64_t length,
                                   au_source **out) {
    if (!source || !out) return AU_INVALID;
    if ((source->capabilities & ranged_source) != ranged_source) return AU_UNSUPPORTED;
    if (offset > source->length || length > source->length - offset) return AU_INVALID;
    au_source *slice = new_source(out, length);
    if (!slice) return AU_NOMEM;
    slice->parent = source->parent ? source->parent : source;
    slice->offset = source->offset + offset;
    au_source_retain(slice->parent);
    return AU_OK;
}

au_status aether_unzip_source_concat(au_source *const *sources, size_t count, au_source **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!sources || !count || count > SIZE_MAX / sizeof(au_segment)) return AU_INVALID;
    uint64_t length = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!sources[i]) return AU_INVALID;
        if ((sources[i]->capabilities & ranged_source) != ranged_source) return AU_UNSUPPORTED;
        if (sources[i]->length > UINT64_MAX - length) return AU_LIMIT;
        length += sources[i]->length;
    }
    au_source *source = new_source(out, length);
    if (!source) return AU_NOMEM;
    if (!length) return AU_OK;
    source->segments = calloc(count, sizeof(*source->segments));
    if (!source->segments) {
        aether_unzip_source_close(source);
        *out = NULL;
        return AU_NOMEM;
    }
    uint64_t start = 0;
    for (size_t i = 0; i < count; ++i) {
        au_source *child = sources[i];
        if (!child->length) continue;
        source->segments[source->segment_count++] = (au_segment){child, start};
        start += child->length;
        au_source_retain(child);
    }
    return AU_OK;
}

void au_source_retain(au_source *source) {
    atomic_fetch_add_explicit(&source->refs, 1, memory_order_relaxed);
}

size_t au_source_parts(const au_source *source) {
    return source->segment_count ? source->segment_count : 1;
}

void au_source_part_range(const au_source *source, size_t part, uint64_t *offset, uint64_t *length) {
    if (source->segment_count) {
        *offset = source->segments[part].start;
        *length = source->segments[part].source->length;
    } else {
        *offset = 0;
        *length = source->length;
    }
}

void aether_unzip_source_close(au_source *source) {
    if (!source || atomic_fetch_sub_explicit(&source->refs, 1, memory_order_acq_rel) != 1) return;
    aether_unzip_source_close(source->parent);
    for (size_t i = 0; i < source->segment_count; ++i)
        aether_unzip_source_close(source->segments[i].source);
    free(source->segments);
    if (source->callbacks.close) source->callbacks.close(source->user);
    if (source->fd >= 0) close(source->fd);
    free(source->data);
    free(source);
}
uint32_t aether_unzip_source_capabilities(const au_source *source) {
    return source ? source->capabilities : 0;
}
au_status aether_unzip_source_length(const au_source *source, uint64_t *length) {
    if (!source || !length) return AU_INVALID;
    if (!(source->capabilities & AU_IO_LENGTH)) return AU_UNSUPPORTED;
    *length = source->length;
    return AU_OK;
}

static au_status read_segments(const au_source *source, uint64_t offset, unsigned char *buffer,
                               size_t capacity, size_t *read_count) {
    size_t first = 0, last = source->segment_count;
    while (last - first > 1) {
        size_t mid = first + (last - first) / 2;
        if (source->segments[mid].start <= offset) first = mid;
        else last = mid;
    }
    for (size_t i = first; capacity; ++i) {
        const au_segment *segment = &source->segments[i];
        uint64_t position = offset - segment->start;
        uint64_t available = segment->source->length - position;
        size_t requested = available < capacity ? (size_t)available : capacity;
        size_t n;
        au_status status = aether_unzip_source_read_at(segment->source, position, buffer,
                                                      requested, &n);
        if (status != AU_OK) return status;
        *read_count += n;
        if (n != requested) return AU_OK;
        buffer += n;
        offset += n;
        capacity -= n;
    }
    return AU_OK;
}

static au_status check_callback_read(au_status status, size_t count, size_t capacity, int sized) {
    if (status != AU_OK) return status < AU_OK ? status : AU_IO;
    if (count > capacity || (sized && !count)) return AU_IO;
    return AU_OK;
}

static au_status callback_read_at(const au_source *source, uint64_t offset, unsigned char *buffer,
                                  size_t capacity, size_t *read_count) {
    size_t total = 0;
    while (total < capacity) {
        size_t count = 0;
        size_t requested = capacity - total;
        au_status status = source->callbacks.read_at(source->user, offset + total, buffer + total,
                                                     requested, &count);
        status = check_callback_read(status, count, requested,
                                     (source->capabilities & AU_IO_LENGTH) != 0);
        if (status != AU_OK) return status;
        if (!count) break;
        total += count;
    }
    *read_count = total;
    return AU_OK;
}

au_status aether_unzip_source_read_at(const au_source *source, uint64_t offset, void *buffer,
                                     size_t capacity, size_t *read_count) {
    if (!source || !read_count || (!buffer && capacity)) return AU_INVALID;
    *read_count = 0;
    if (!(source->capabilities & AU_IO_RANDOM)) return AU_UNSUPPORTED;
    uint64_t end = (source->capabilities & AU_IO_LENGTH) ? source->length : UINT64_MAX;
    if (!capacity || offset >= end) return AU_OK;
    if (capacity > end - offset) capacity = (size_t)(end - offset);
    if (source->callbacks.read_at)
        return callback_read_at(source, offset, buffer, capacity, read_count);
    if (source->parent)
        return aether_unzip_source_read_at(source->parent, source->offset + offset, buffer,
                                          capacity, read_count);
    if (source->segment_count) return read_segments(source, offset, buffer, capacity, read_count);
    if (source->fd >= 0) {
        if (capacity > SSIZE_MAX) capacity = SSIZE_MAX;
        ssize_t n;
        do { n = pread(source->fd, buffer, capacity, (off_t)offset); }
        while (n < 0 && errno == EINTR);
        if (n <= 0) return AU_IO;
        *read_count = (size_t)n;
    } else {
        memcpy(buffer, source->data + offset, capacity);
        *read_count = capacity;
    }
    return AU_OK;
}

au_status aether_unzip_source_read(au_source *source, void *buffer, size_t capacity,
                                  size_t *read_count) {
    if (!source || !read_count || (!buffer && capacity)) return AU_INVALID;
    if (source->callbacks.read) {
        *read_count = 0;
        int sized = (source->capabilities & AU_IO_LENGTH) != 0;
        uint64_t end = sized ? source->length : UINT64_MAX;
        if (!capacity || source->cursor == end) return AU_OK;
        if (capacity > end - source->cursor) capacity = (size_t)(end - source->cursor);
        size_t count = 0;
        au_status status = source->callbacks.read(source->user, buffer, capacity, &count);
        status = check_callback_read(status, count, capacity, sized);
        if (status != AU_OK) return status;
        source->cursor += count;
        *read_count = count;
        return AU_OK;
    }
    au_status status = aether_unzip_source_read_at(source, source->cursor, buffer, capacity,
                                                  read_count);
    if (status == AU_OK) source->cursor += *read_count;
    return status;
}

au_status aether_unzip_sink_file(const char *path, au_sink **out) {
    if (!path || !out) return AU_INVALID;
    *out = NULL;
    au_sink *sink = calloc(1, sizeof(*sink));
    if (!sink) return AU_NOMEM;
    sink->fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (sink->fd < 0) {
        int error = errno;
        free(sink);
        return error == EEXIST ? AU_EXISTS : AU_IO;
    }
    *out = sink;
    return AU_OK;
}
au_status aether_unzip_sink_memory(size_t limit, au_sink **out) {
    if (!out) return AU_INVALID;
    *out = calloc(1, sizeof(**out));
    if (!*out) return AU_NOMEM;
    (*out)->fd = -1;
    (*out)->limit = limit;
    return AU_OK;
}

au_status aether_unzip_sink_callback(const au_sink_callbacks *callbacks, void *user, au_sink **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!callbacks || callbacks->struct_size < sizeof(*callbacks) ||
        (!callbacks->write && !callbacks->write_at)) return AU_INVALID;
    au_status status = aether_unzip_sink_memory(0, out);
    if (status != AU_OK) return status;
    (*out)->callbacks = *callbacks;
    (*out)->user = user;
    return AU_OK;
}

uint32_t aether_unzip_sink_capabilities(const au_sink *sink) {
    if (!sink) return 0;
    return sink->callbacks.write && !sink->callbacks.write_at
        ? AU_IO_SEQUENTIAL : AU_IO_SEQUENTIAL | AU_IO_RANDOM;
}

static au_status reserve(au_sink *sink, size_t end) {
    if (end <= sink->capacity) return AU_OK;
    if (end > sink->limit) return AU_LIMIT;
    size_t capacity = sink->capacity > sink->limit / 2 ? sink->limit : sink->capacity * 2;
    if (capacity < end) capacity = end;
    void *data = realloc(sink->data, capacity);
    if (!data) return AU_NOMEM;
    sink->data = data;
    sink->capacity = capacity;
    return AU_OK;
}

au_status aether_unzip_sink_write_at(au_sink *sink, uint64_t offset, const void *data, size_t size) {
    if (!sink || (!data && size)) return AU_INVALID;
    if (!(aether_unzip_sink_capabilities(sink) & AU_IO_RANDOM)) return AU_UNSUPPORTED;
    if (!size) return AU_OK;
    if (size > UINT64_MAX - offset) return AU_LIMIT;
    if (sink->callbacks.write_at) return sink->callbacks.write_at(sink->user, offset, data, size);
    if (sink->fd >= 0) {
        if (offset > INT64_MAX || size > INT64_MAX - offset) return AU_LIMIT;
        const unsigned char *bytes = data;
        while (size) {
            ssize_t n = pwrite(sink->fd, bytes, size > SSIZE_MAX ? SSIZE_MAX : size, (off_t)offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return AU_IO;
            bytes += n;
            size -= (size_t)n;
            offset += (uint64_t)n;
        }
        return AU_OK;
    }
    if (offset > SIZE_MAX || size > SIZE_MAX - offset) return AU_LIMIT;
    size_t end = (size_t)offset + size;
    au_status status = reserve(sink, end);
    if (status != AU_OK) return status;
    if (offset > sink->length) memset(sink->data + sink->length, 0, offset - sink->length);
    memcpy(sink->data + offset, data, size);
    if (end > sink->length) sink->length = end;
    return AU_OK;
}

au_status aether_unzip_sink_write(au_sink *sink, const void *data, size_t size) {
    if (!sink || (!data && size)) return AU_INVALID;
    if (!size) return AU_OK;
    if (size > UINT64_MAX - sink->cursor) return AU_LIMIT;
    au_status status = sink->callbacks.write
        ? sink->callbacks.write(sink->user, data, size)
        : aether_unzip_sink_write_at(sink, sink->cursor, data, size);
    if (status == AU_OK) sink->cursor += size;
    return status;
}
au_status aether_unzip_sink_flush(au_sink *sink) {
    if (!sink) return AU_INVALID;
    if (sink->callbacks.flush) return sink->callbacks.flush(sink->user);
    if (sink->fd < 0) return AU_OK;
    int result;
    do { result = fsync(sink->fd); } while (result && errno == EINTR);
    return result ? AU_IO : AU_OK;
}
au_status aether_unzip_sink_memory_view(const au_sink *sink, const void **data, size_t *size) {
    if (!sink || !data || !size || sink->fd >= 0) return AU_INVALID;
    if (sink->callbacks.write || sink->callbacks.write_at) return AU_UNSUPPORTED;
    *data = sink->data;
    *size = sink->length;
    return AU_OK;
}
au_status aether_unzip_sink_close(au_sink *sink) {
    if (!sink) return AU_OK;
    au_status status = sink->callbacks.close ? sink->callbacks.close(sink->user) : AU_OK;
    if (sink->fd >= 0 && close(sink->fd)) status = AU_IO;
    free(sink->data);
    free(sink);
    return status;
}
