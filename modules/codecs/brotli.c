#include "internal.h"
#include <brotli/decode.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define BROTLI_CAPABILITIES (AU_CAN_LIST | AU_CAN_EXTRACT | AU_CAN_READ)
#define PROBE_INPUT_LIMIT (1024u * 1024u)

typedef struct {
    BrotliDecoderState *decoder;
    au_source *source;
    au_options options;
    char *name;
    uint64_t length, position;
    const uint8_t *next_input;
    size_t available;
    uint8_t first_byte;
    int first_pending;
    int emitted_entry;
    int finished;
    uint8_t buffer[32768];
} brotli_reader;

static void close_reader(void *data) {
    brotli_reader *reader = data;
    BrotliDecoderDestroyInstance(reader->decoder);
    aether_unzip_source_close(reader->source);
    free(reader->name);
    free(reader);
}

static au_status decode(brotli_reader *reader, uint8_t *output, size_t capacity,
                        uint64_t input_limit, size_t *count) {
    *count = 0;
    if (!capacity || reader->finished) return AU_OK;
    size_t available_output = capacity;
    for (;;) {
        if (au_cancelled(&reader->options)) return AU_CANCELLED;
        BrotliDecoderResult result = BrotliDecoderDecompressStream(reader->decoder,
            &reader->available, &reader->next_input, &available_output, &output, NULL);
        if (result == BROTLI_DECODER_RESULT_ERROR) return AU_CORRUPT;
        if (result == BROTLI_DECODER_RESULT_SUCCESS) {
            if (reader->available || reader->position != reader->length) return AU_CORRUPT;
            reader->finished = 1;
        }
        if (result != BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT || capacity != available_output) {
            *count = capacity - available_output;
            return AU_OK;
        }
        if (reader->position >= reader->length) return AU_CORRUPT;
        if (reader->position >= input_limit) return AU_LIMIT;
        size_t size = sizeof(reader->buffer);
        if (size > input_limit - reader->position) size = (size_t)(input_limit - reader->position);
        au_status status = aether_unzip_source_read_at(reader->source, reader->position,
                                                       reader->buffer, size, &reader->available);
        if (status != AU_OK) return status;
        if (!reader->available) return AU_IO;
        reader->position += reader->available;
        reader->next_input = reader->buffer;
    }
}

static au_status probe(au_source *source, const char *hint, const char *passphrase,
                       const au_options *options, au_probe_result *info, void **output) {
    (void)passphrase;
    const char *base = hint ? strrchr(hint, '/') : NULL;
    base = base ? base + 1 : hint;
    const char *extension = base ? strrchr(base, '.') : NULL;
    if (!extension || strcasecmp(extension, ".br")) return AU_UNKNOWN_FORMAT;
    info->candidate = info->extension_hint = AU_FORMAT_BROTLI;
    info->evidence |= AU_EVIDENCE_EXTENSION;

    brotli_reader *reader = calloc(1, sizeof(*reader));
    if (!reader) return AU_NOMEM;
    reader->source = source;
    au_source_retain(source);
    reader->options = *options;
    au_status status = aether_unzip_source_length(source, &reader->length);
    if (status != AU_OK) {
        close_reader(reader);
        return status;
    }
    size_t length = (size_t)(extension - base);
    if (length > 4096) {
        close_reader(reader);
        return AU_LIMIT;
    }
    reader->name = !length || (length == 1 && *base == '.') ||
        (length == 2 && !memcmp(base, "..", 2)) || !au_valid_utf8(base)
        ? strdup("data") : strndup(base, length);
    reader->decoder = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    if (!reader->decoder || !reader->name) {
        close_reader(reader);
        return AU_NOMEM;
    }

    size_t count;
    status = decode(reader, &reader->first_byte, 1, PROBE_INPUT_LIMIT, &count);
    if (status != AU_OK) {
        close_reader(reader);
        return status;
    }
    reader->first_pending = count != 0;
    info->format = info->filter = AU_FORMAT_BROTLI;
    info->kind = AU_KIND_STREAM;
    info->evidence |= AU_EVIDENCE_STRUCTURE;
    info->capabilities = BROTLI_CAPABILITIES;
    *output = reader;
    return AU_OK;
}

static au_status next(void *data, au_entry *entry) {
    brotli_reader *reader = data;
    if (reader->emitted_entry) return AU_END;
    reader->emitted_entry = 1;
    entry->kind = AU_ENTRY_FILE;
    entry->name = reader->name;
    entry->name_length = strlen(reader->name);
    entry->size_known = reader->finished && !reader->first_pending;
    return AU_OK;
}

static au_status read(void *data, void *buffer, size_t size, size_t *n) {
    brotli_reader *reader = data;
    if (size && reader->first_pending) {
        *(uint8_t *)buffer = reader->first_byte;
        reader->first_pending = 0;
        *n = 1;
        return AU_OK;
    }
    return decode(reader, buffer, size, UINT64_MAX, n);
}

static au_status skip(void *data, int catalog_only, int *skipped) {
    (void)catalog_only;
    (void)data;
    *skipped = 1;
    return AU_OK;
}

static const au_format supported[] = {AU_FORMAT_BROTLI};
const au_driver au_brotli_driver = {
    .info = {sizeof(au_driver_info), 1, "brotli", BROTLI_CAPABILITIES, 1, supported},
    .probe = probe, .next = next, .read = read, .skip = skip, .close = close_reader
};
