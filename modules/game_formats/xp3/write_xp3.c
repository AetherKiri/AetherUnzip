#include "internal.h"
#include "format.h"
#include <errno.h>
#include <iconv.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

enum { CHUNK_HEADER = 12, INFO_FIXED = 22, DIGEST_SIZE = 4 };

typedef struct {
    int fd;
    iconv_t names;
    uint8_t *index;
    size_t index_size, capacity;
    uint64_t position, offset, size;
    uLong digest;
    int directory;
    uint8_t name[8192];
    size_t name_size;
} writer;

static void put_le(uint8_t *out, uint64_t value, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        out[i] = (uint8_t)value;
        value >>= 8;
    }
}

static uint8_t *chunk(uint8_t *out, const char *tag, size_t size) {
    memcpy(out, tag, 4);
    put_le(out + 4, size, 8);
    return out + CHUNK_HEADER;
}

static au_status begin(void *opaque, const char *path, const struct stat *info) {
    writer *state = opaque;
    state->directory = S_ISDIR(info->st_mode);
    if (state->directory) return AU_OK;
    char *source = (char *)path;
    char *result = (char *)state->name;
    size_t input = strlen(path), available = sizeof(state->name);
    if (iconv(state->names, &source, &input, &result, &available) == (size_t)-1)
        return errno == E2BIG ? AU_LIMIT : AU_UNSAFE_PATH;
    state->name_size = sizeof(state->name) - available;
    state->offset = state->position;
    state->size = (uint64_t)info->st_size;
    state->digest = adler32(0, Z_NULL, 0);
    return AU_OK;
}

static au_status write_bytes(void *opaque, const void *data, size_t count) {
    writer *state = opaque;
    au_status status = au_write_all(state->fd, data, count);
    if (status != AU_OK) return status;
    state->position += count;
    state->digest = adler32(state->digest, data, (uInt)count);
    return AU_OK;
}

static au_status end(void *opaque) {
    writer *state = opaque;
    /* XP3 stores files with relative paths. It has no empty-directory entries. */
    if (state->directory) return AU_OK;
    size_t info_size = INFO_FIXED + state->name_size;
    size_t payload = 3 * CHUNK_HEADER + info_size + XP3_SEGMENT + DIGEST_SIZE;
    size_t needed = state->index_size + CHUNK_HEADER + payload;
    if (needed > XP3_INDEX_BUDGET) return AU_LIMIT;
    if (needed > state->capacity) {
        size_t capacity = state->capacity ? state->capacity * 2 : 4096;
        if (capacity < needed) capacity = needed;
        if (capacity > XP3_INDEX_BUDGET) capacity = XP3_INDEX_BUDGET;
        uint8_t *index = realloc(state->index, capacity);
        if (!index) return AU_NOMEM;
        state->index = index;
        state->capacity = capacity;
    }

    uint8_t *file = chunk(state->index + state->index_size, "File", payload);
    uint8_t *info = chunk(file, "info", info_size);
    put_le(info, 0, 4); /* Standard unprotected file. */
    put_le(info + 4, state->size, 8);
    put_le(info + 12, state->size, 8);
    put_le(info + 20, state->name_size / 2, 2);
    memcpy(info + INFO_FIXED, state->name, state->name_size);

    uint8_t *segment = chunk(info + info_size, "segm", XP3_SEGMENT);
    put_le(segment, 0, 4); /* Stored segment. */
    put_le(segment + 4, state->offset, 8);
    put_le(segment + 12, state->size, 8);
    put_le(segment + 20, state->size, 8);
    put_le(chunk(segment + XP3_SEGMENT, "adlr", DIGEST_SIZE), state->digest, DIGEST_SIZE);
    state->index_size = needed;
    return AU_OK;
}

static au_status finish(void *opaque) {
    writer *state = opaque;
    if (!state->index_size) return AU_INVALID;
    uint8_t index_header[9] = {0}; /* One uncompressed index block. */
    put_le(index_header + 1, state->index_size, 8);
    au_status status = au_write_all(state->fd, index_header, sizeof(index_header));
    if (status == AU_OK) status = au_write_all(state->fd, state->index, state->index_size);
    if (status != AU_OK) return status;
    if (lseek(state->fd, (off_t)sizeof(xp3_magic), SEEK_SET) < 0) return au_output_error(errno);
    uint8_t pointer[8];
    put_le(pointer, state->position, sizeof(pointer));
    return au_write_all(state->fd, pointer, sizeof(pointer));
}

static void destroy(void *opaque) {
    writer *state = opaque;
    iconv_close(state->names);
    free(state->index);
    free(state);
}

au_status au_xp3_encoder_open(int fd, au_encoder *out) {
    writer *state = calloc(1, sizeof(*state));
    if (!state) return AU_NOMEM;
    state->names = iconv_open("UTF-16LE", "UTF-8");
    if (state->names == (iconv_t)-1) { free(state); return AU_UNSUPPORTED; }
    state->fd = fd;
    state->position = XP3_HEADER;
    uint8_t header[XP3_HEADER] = {0};
    memcpy(header, xp3_magic, sizeof(xp3_magic));
    au_status status = au_write_all(fd, header, sizeof(header));
    if (status != AU_OK) { destroy(state); return status; }
    *out = (au_encoder){state, begin, write_bytes, end, finish, destroy};
    return AU_OK;
}
