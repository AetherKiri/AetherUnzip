#include "internal.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <zlib.h>

enum { XP3_HEADER = 19, XP3_SEGMENT = 28, XP3_MAX_BLOCKS = 256 };
#define XP3_INDEX_BUDGET (UINT64_C(32) * 1024 * 1024)
#define XP3_PREFIX_BUDGET (UINT64_C(16) * 1024 * 1024)
#define XP3_PROTECTED UINT32_C(0x80000000)
#define XP3_CAPABILITIES (AU_CAN_LIST | AU_CAN_EXTRACT | AU_CAN_READ | AU_REQUIRES_SEEKABLE_SOURCE)

static const uint8_t magic[] = {'X', 'P', '3', 13, 10, 32, 10, 26, 0x8b, 0x67, 1};

typedef struct {
    const uint8_t *data;
    size_t size;
} view;

typedef struct {
    uint64_t offset, size, packed;
    int compressed;
} segment;

typedef struct {
    char *name;
    uint64_t size;
    uint32_t digest;
    uint32_t kind;
    segment *segments;
    size_t segment_count;
} item;

typedef struct {
    z_stream z;
    uint64_t position, packed_left, output_left;
    int compressed, active, finished;
    uint8_t input[32768];
} stream;

typedef struct {
    au_source *source;
    au_options options;
    uint64_t length;
    item *items;
    size_t count, capacity, cursor, segment_index;
    const item *current;
    stream bytes;
    uLong digest;
} reader;

static uint32_t le32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
           (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint64_t le64(const uint8_t *bytes) {
    return le32(bytes) | (uint64_t)le32(bytes + 4) << 32;
}

static au_status read_exact(const reader *state, uint64_t at, void *destination, size_t size) {
    if (at > state->length || size > state->length - at) return AU_CORRUPT;
    uint8_t *out = destination;
    while (size) {
        if (au_cancelled(&state->options)) return AU_CANCELLED;
        size_t amount = 0;
        size_t requested = size < 65536 ? size : 65536;
        au_status status = aether_unzip_source_read_at(state->source, at, out, requested, &amount);
        if (status != AU_OK) return status;
        if (!amount) return AU_CORRUPT;
        at += amount;
        out += amount;
        size -= amount;
    }
    return AU_OK;
}

static void reset_stream(stream *input) {
    if (input->active && input->compressed) inflateEnd(&input->z);
    memset(&input->z, 0, sizeof(input->z));
    input->active = 0;
    input->finished = 0;
}

static au_status start_stream(stream *input, segment part) {
    reset_stream(input);
    input->position = part.offset;
    input->packed_left = part.packed;
    input->output_left = part.size;
    input->compressed = part.compressed;
    if (part.compressed) {
        int status = inflateInit(&input->z);
        if (status != Z_OK) return status == Z_MEM_ERROR ? AU_NOMEM : AU_CORRUPT;
    }
    input->active = 1;
    return AU_OK;
}

static au_status stream_read(const reader *state, stream *input, uint8_t *out, size_t capacity,
                             size_t *count) {
    *count = 0;
    if (input->finished) return AU_OK;
    if (capacity > input->output_left) capacity = (size_t)input->output_left;
    if (!input->compressed) {
        au_status status = read_exact(state, input->position, out, capacity);
        if (status != AU_OK) return status;
        input->position += capacity;
        input->output_left -= capacity;
        input->finished = !input->output_left;
        *count = capacity;
        return AU_OK;
    }

    // When the advertised output is exhausted, still consume and validate the zlib trailer.
    uint8_t extra;
    z_stream *z = &input->z;
    z->next_out = capacity ? out : &extra;
    z->avail_out = (uInt)(capacity ? capacity : 1);
    for (;;) {
        if (au_cancelled(&state->options)) return AU_CANCELLED;
        if (!z->avail_in && input->packed_left) {
            size_t amount = sizeof(input->input);
            if (amount > input->packed_left) amount = (size_t)input->packed_left;
            au_status status = read_exact(state, input->position, input->input, amount);
            if (status != AU_OK) return status;
            input->position += amount;
            input->packed_left -= amount;
            z->next_in = input->input;
            z->avail_in = (uInt)amount;
        }
        uInt in_before = z->avail_in, out_before = z->avail_out;
        int status = inflate(z, Z_NO_FLUSH);
        size_t written = out_before - z->avail_out;
        if (written > input->output_left) return AU_CORRUPT;
        input->output_left -= written;
        *count += written;
        if (status == Z_STREAM_END) {
            if (z->avail_in || input->packed_left || input->output_left) return AU_CORRUPT;
            input->finished = 1;
            return AU_OK;
        }
        if (status == Z_MEM_ERROR) return AU_NOMEM;
        if (status != Z_OK || (in_before == z->avail_in && !written)) return AU_CORRUPT;
        if (!z->avail_out) return AU_OK;
    }
}

static uint16_t le16(const uint8_t *bytes) {
    return (uint16_t)(bytes[0] | (uint16_t)bytes[1] << 8);
}

static au_status decode_name(view info, char **name) {
    size_t count = le16(info.data + 20);
    if (!count || count * 2 > info.size - 22) return AU_CORRUPT;
    char *text = malloc(count * 3 + 1);
    if (!text) return AU_NOMEM;
    size_t size = 0;
    const uint8_t *utf16 = info.data + 22;
    for (size_t i = 0; i < count; ++i) {
        uint32_t code = le16(utf16 + i * 2);
        if (!code || (code >= 0xdc00 && code <= 0xdfff)) break;
        if (code >= 0xd800 && code <= 0xdbff) {
            if (++i == count) break;
            uint32_t low = le16(utf16 + i * 2);
            if (low < 0xdc00 || low > 0xdfff) break;
            code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00;
        }

        if (code < 0x80) {
            text[size++] = (char)code;
        } else {
            if (code < 0x800) text[size++] = (char)(0xc0 | (code >> 6));
            else {
                if (code >= 0x10000) {
                    text[size++] = (char)(0xf0 | (code >> 18));
                    text[size++] = (char)(0x80 | ((code >> 12) & 63));
                } else text[size++] = (char)(0xe0 | (code >> 12));
                text[size++] = (char)(0x80 | ((code >> 6) & 63));
            }
            text[size++] = (char)(0x80 | (code & 63));
        }

        if (i + 1 == count) {
            text[size] = '\0';
            *name = text;
            return AU_OK;
        }
    }
    free(text);
    return AU_CORRUPT;
}

static au_status read_chunk(view *input, const uint8_t **tag, view *chunk) {
    if (input->size < 12) return AU_CORRUPT;
    uint64_t size = le64(input->data + 4);
    if (size > input->size - 12) return AU_CORRUPT;
    *tag = input->data;
    *chunk = (view){input->data + 12, (size_t)size};
    input->data += 12 + chunk->size;
    input->size -= 12 + chunk->size;
    return AU_OK;
}

static au_status read_segments(const reader *state, view data, item *entry, uint64_t packed) {
    if (data.size % XP3_SEGMENT) return AU_CORRUPT;
    size_t count = data.size / XP3_SEGMENT;
    if (!count) return !entry->size && !packed ? AU_OK : AU_CORRUPT;
    entry->segments = calloc(count, sizeof(*entry->segments));
    if (!entry->segments) return AU_NOMEM;
    entry->segment_count = count;
    uint64_t remaining = entry->size;
    const uint8_t *bytes = data.data;
    for (size_t i = 0; i < count; ++i, bytes += XP3_SEGMENT) {
        if (au_cancelled(&state->options)) return AU_CANCELLED;
        uint32_t method = le32(bytes);
        segment part = {le64(bytes + 4), le64(bytes + 12), le64(bytes + 20), method == 1};
        if (method > 1) entry->kind = AU_ENTRY_OTHER;
        if (part.size > remaining || part.packed > packed || part.offset > state->length ||
            part.packed > state->length - part.offset || (part.packed && part.offset < XP3_HEADER) ||
            (method == 0 && part.size != part.packed)) return AU_CORRUPT;
        packed -= part.packed;
        remaining -= part.size;
        entry->segments[i] = part;
    }
    return !remaining && !packed ? AU_OK : AU_CORRUPT;
}

static au_status read_item(reader *state, view payload) {
    view info = {0}, segments = {0}, digest = {0};
    while (payload.size) {
        if (au_cancelled(&state->options)) return AU_CANCELLED;
        const uint8_t *tag;
        view chunk;
        au_status status = read_chunk(&payload, &tag, &chunk);
        if (status != AU_OK) return status;
        view *field = NULL;
        if (!memcmp(tag, "info", 4)) field = &info;
        else if (!memcmp(tag, "segm", 4)) field = &segments;
        else if (!memcmp(tag, "adlr", 4)) field = &digest;
        if (field) {
            if (field->data) return AU_CORRUPT;
            *field = chunk;
        }
    }
    if (info.size < 22 || !segments.data || digest.size != 4) return AU_CORRUPT;
    if (state->count >= state->options.max_entries) return AU_LIMIT;
    if (state->count == state->capacity) {
        size_t capacity = state->capacity ? state->capacity * 2 : 8;
        if (capacity > state->options.max_entries) capacity = (size_t)state->options.max_entries;
        item *items = realloc(state->items, capacity * sizeof(*items));
        if (!items) return AU_NOMEM;
        state->items = items;
        state->capacity = capacity;
    }
    item *entry = &state->items[state->count++];
    *entry = (item){.size = le64(info.data + 4), .digest = le32(digest.data),
                    .kind = (le32(info.data) & XP3_PROTECTED) ? AU_ENTRY_OTHER : AU_ENTRY_FILE};
    au_status status = decode_name(info, &entry->name);
    if (status != AU_OK) return status;
    return read_segments(state, segments, entry, le64(info.data + 12));
}

static au_status read_index(reader *state) {
    uint64_t pointer = sizeof(magic);
    uint64_t used = 0, packed_total = 0;
    uint64_t visited[XP3_MAX_BLOCKS];
    for (size_t block = 0; block < XP3_MAX_BLOCKS; ++block) {
        uint8_t header[17];
        au_status status = read_exact(state, pointer, header, 8);
        if (status != AU_OK) return status;
        uint64_t at = le64(header);
        if (at < XP3_HEADER) return AU_CORRUPT;
        for (size_t i = 0; i < block; ++i)
            if (visited[i] == at) return AU_CORRUPT;
        visited[block] = at;
        status = read_exact(state, at, header, 9);
        if (status != AU_OK) return status;
        unsigned flags = header[0];
        unsigned method = flags & 0x7f;
        if (method > 1) return AU_UNSUPPORTED;
        uint64_t packed = le64(header + 1);
        at += 9;
        uint64_t size = packed;
        if (method == 1) {
            status = read_exact(state, at, header, 8);
            if (status != AU_OK) return status;
            size = le64(header);
            at += 8;
        }
        if (packed > state->length - at) return AU_CORRUPT;
        if (size > XP3_INDEX_BUDGET - used || packed > XP3_INDEX_BUDGET - packed_total)
            return AU_LIMIT;
        used += size;
        packed_total += packed;
        uint8_t *data = malloc(size ? (size_t)size : 1);
        if (!data) return AU_NOMEM;
        stream *input = &state->bytes;
        status = start_stream(input, (segment){at, size, packed, method == 1});
        size_t count = 0;
        if (status == AU_OK) status = stream_read(state, input, data, (size_t)size, &count);
        if (status == AU_OK && count != size) status = AU_CORRUPT;
        if (status == AU_OK && !input->finished) {
            size_t extra;
            status = stream_read(state, input, data, 0, &extra);
            if (status == AU_OK && !input->finished) status = AU_CORRUPT;
        }
        reset_stream(input);
        view index = {data, count};
        while (status == AU_OK && index.size) {
            if (au_cancelled(&state->options)) { status = AU_CANCELLED; break; }
            const uint8_t *tag;
            view payload;
            status = read_chunk(&index, &tag, &payload);
            if (status == AU_OK && !memcmp(tag, "File", 4)) status = read_item(state, payload);
        }
        free(data);
        if (status != AU_OK || !(flags & 0x80)) return status;
        pointer = at + packed;
    }
    return AU_LIMIT;
}

static void close_reader(void *opaque) {
    reader *state = opaque;
    reset_stream(&state->bytes);
    for (size_t i = 0; i < state->count; ++i) {
        free(state->items[i].name);
        free(state->items[i].segments);
    }
    free(state->items);
    aether_unzip_source_close(state->source);
    free(state);
}

static au_status locate(au_source *source, uint64_t length, const au_options *options,
                        uint64_t *offset) {
    uint8_t header[sizeof(magic)];
    size_t count = 0;
    au_status status = aether_unzip_source_read_at(source, 0, header, sizeof(header), &count);
    if (status != AU_OK) return status;
    if (count == sizeof(magic) && !memcmp(header, magic, sizeof(magic))) {
        *offset = 0;
        return AU_OK;
    }
    if (count < 2 || memcmp(header, "MZ", 2)) return AU_UNKNOWN_FORMAT;

    // KiriKiri aligns the XP3 signature on a 16-byte boundary in MZ wrappers.
    uint8_t block[32768];
    uint64_t end = length < XP3_PREFIX_BUDGET ? length : XP3_PREFIX_BUDGET;
    for (uint64_t at = 16; at + sizeof(magic) <= end;) {
        if (au_cancelled(options)) return AU_CANCELLED;
        size_t request = end - at < sizeof(block) ? (size_t)(end - at) : sizeof(block);
        status = aether_unzip_source_read_at(source, at, block, request, &count);
        if (status != AU_OK) return status;
        if (count != request) return AU_IO;
        for (size_t i = 0; i + sizeof(magic) <= count; i += 16) {
            if (!memcmp(block + i, magic, sizeof(magic))) {
                *offset = at + i;
                return AU_OK;
            }
        }
        at += count;
    }
    return AU_UNKNOWN_FORMAT;
}

static au_status probe(au_source *source, const char *hint, const char *passphrase,
                       const au_options *options, au_probe_result *info, void **out) {
    (void)passphrase;
    const char *extension = hint ? strrchr(hint, '.') : NULL;
    int hinted = extension && !strcasecmp(extension, ".xp3");
    if (hinted && !info->extension_hint) {
        info->extension_hint = AU_FORMAT_XP3;
        info->evidence |= AU_EVIDENCE_EXTENSION;
    }
    uint64_t length, offset;
    au_status status = aether_unzip_source_length(source, &length);
    if (status != AU_OK) return status;
    status = locate(source, length, options, &offset);
    if (status != AU_OK) return status;
    info->candidate = AU_FORMAT_XP3;
    info->evidence |= AU_EVIDENCE_MAGIC;
    reader *state = calloc(1, sizeof(*state));
    if (!state) return AU_NOMEM;
    if (offset) {
        status = aether_unzip_source_slice(source, offset, length - offset, &state->source);
    } else {
        au_source_retain(source);
        state->source = source;
    }
    state->options = *options;
    state->length = length - offset;
    if (status == AU_OK) status = read_index(state);
    if (status != AU_OK) {
        close_reader(state);
        return status;
    }
    info->format = AU_FORMAT_XP3;
    info->kind = AU_KIND_CONTAINER;
    info->evidence |= AU_EVIDENCE_STRUCTURE;
    info->capabilities = XP3_CAPABILITIES;
    *out = state;
    return AU_OK;
}

static au_status next(void *opaque, au_entry *out) {
    reader *state = opaque;
    if (state->cursor == state->count) return AU_END;
    state->current = &state->items[state->cursor++];
    state->segment_index = 0;
    state->digest = adler32(0L, Z_NULL, 0);
    const item *entry = state->current;
    out->kind = entry->kind;
    out->name = entry->name;
    out->name_length = strlen(entry->name);
    out->size = entry->size;
    out->size_known = 1;
    return AU_OK;
}

static au_status read_data(void *opaque, void *buffer, size_t capacity, size_t *count) {
    reader *state = opaque;
    const item *entry = state->current;
    *count = 0;
    if (entry->kind != AU_ENTRY_FILE) return AU_UNSUPPORTED;
    stream *input = &state->bytes;
    while (state->segment_index < entry->segment_count) {
        if (!input->active) {
            au_status status = start_stream(input, entry->segments[state->segment_index]);
            if (status != AU_OK) return status;
        }
        au_status status = stream_read(state, input, buffer, capacity, count);
        if (status != AU_OK) return status;
        if (input->finished) {
            ++state->segment_index;
            reset_stream(input);
        }
        if (*count) {
            state->digest = adler32(state->digest, buffer, (uInt)*count);
            return AU_OK;
        }
    }
    return state->digest == entry->digest ? AU_OK : AU_CORRUPT;
}

static au_status skip(void *opaque, int catalog_only, int *skipped) {
    (void)catalog_only;
    reader *state = opaque;
    reset_stream(&state->bytes);
    *skipped = 1;
    return AU_OK;
}

static const au_format supported[] = {AU_FORMAT_XP3};
const au_driver au_xp3_driver = {
    .info = {sizeof(au_driver_info), 1, "xp3", XP3_CAPABILITIES, 1, supported},
    .probe = probe, .next = next, .read = read_data, .skip = skip, .close = close_reader
};
