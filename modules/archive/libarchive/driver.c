#include "internal.h"
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <limits.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#define BASE_CAPABILITIES (AU_CAN_LIST | AU_CAN_EXTRACT | AU_CAN_READ)
#define NAME_LIMIT 4096

typedef struct reader reader;
typedef struct {
    reader *owner;
    uint64_t offset, length, position;
} reader_volume;

struct reader {
    struct archive *handle;
    struct archive_entry *pending;
    au_source *source;
    au_options options;
    au_status input_error;
    uint64_t length;
    reader_volume primary;
    reader_volume *volumes;
    au_format format;
    locale_t locale;
    char *stream_name;
    int first, raw;
    unsigned char buffer[65536];
};

static la_ssize_t pull(struct archive *handle, void *data, const void **buffer) {
    reader_volume *volume = data;
    reader *state = volume->owner;
    size_t n = 0;
    uint64_t available = volume->length - volume->position;
    size_t size = available < sizeof(state->buffer) ? (size_t)available : sizeof(state->buffer);
    state->input_error = au_cancelled(&state->options) ? AU_CANCELLED :
        aether_unzip_source_read_at(state->source, volume->offset + volume->position,
                                    state->buffer, size, &n);
    if (state->input_error != AU_OK) {
        archive_set_error(handle, EIO, "%s", aether_unzip_error_message(state->input_error));
        return -1;
    }
    volume->position += n;
    *buffer = state->buffer;
    return (la_ssize_t)n;
}

static la_int64_t skip_input(struct archive *handle, void *data, la_int64_t request) {
    (void)handle;
    reader_volume *volume = data;
    if (request <= 0) return 0;
    uint64_t n = (uint64_t)request;
    if (n > volume->length - volume->position) n = volume->length - volume->position;
    volume->position += n;
    return (la_int64_t)n;
}

static la_int64_t seek_input(struct archive *handle, void *data, la_int64_t offset, int whence) {
    (void)handle;
    reader_volume *volume = data;
    uint64_t base;
    switch (whence) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = volume->position; break;
    case SEEK_END: base = volume->length; break;
    default: return ARCHIVE_FATAL;
    }
    if (offset < 0) {
        uint64_t backwards = (uint64_t)(-(offset + 1)) + 1;
        if (backwards > base) return ARCHIVE_FATAL;
        volume->position = base - backwards;
    } else {
        if ((uint64_t)offset > volume->length - base) return ARCHIVE_FATAL;
        volume->position = base + (uint64_t)offset;
    }
    return (la_int64_t)volume->position;
}

static int switch_volume(struct archive *handle, void *from, void *to) {
    (void)handle;
    (void)from;
    reader_volume *volume = to;
    volume->position = 0;
    return ARCHIVE_OK;
}

static au_status set_input(reader *state, au_format candidate) {
    size_t parts = au_source_parts(state->source);
    if (parts == 1 || (candidate != AU_FORMAT_ZIP && candidate != AU_FORMAT_UNKNOWN)) {
        state->primary = (reader_volume){.owner = state, .length = state->length};
        return archive_read_set_callback_data(state->handle, &state->primary) == ARCHIVE_OK
            ? AU_OK : AU_NOMEM;
    }
    if (parts > UINT_MAX || parts > SIZE_MAX / sizeof(*state->volumes)) return AU_LIMIT;
    state->volumes = calloc(parts, sizeof(*state->volumes));
    if (!state->volumes) return AU_NOMEM;
    archive_read_set_switch_callback(state->handle, switch_volume);
    for (size_t i = 0; i < parts; ++i) {
        reader_volume *volume = &state->volumes[i];
        volume->owner = state;
        au_source_part_range(state->source, i, &volume->offset, &volume->length);
        if (archive_read_append_callback_data(state->handle, volume) != ARCHIVE_OK)
            return AU_NOMEM;
    }
    return AU_OK;
}

static au_format extension(const char *name) {
    const char *dot = name ? strrchr(name, '.') : NULL;
    if (!dot) return AU_FORMAT_UNKNOWN;
    ++dot;
    if (!strcasecmp(dot, "zip")) return AU_FORMAT_ZIP;
    if (!strcasecmp(dot, "tar")) return AU_FORMAT_TAR;
    if (!strcasecmp(dot, "7z")) return AU_FORMAT_7ZIP;
    if (!strcasecmp(dot, "rar")) return AU_FORMAT_RAR;
    if (!strcasecmp(dot, "gz") || !strcasecmp(dot, "tgz")) return AU_FORMAT_GZIP;
    if (!strcasecmp(dot, "lz4")) return AU_FORMAT_LZ4;
    if (!strcasecmp(dot, "zst") || !strcasecmp(dot, "zstd")) return AU_FORMAT_ZSTD;
    if (!strcasecmp(dot, "xz") || !strcasecmp(dot, "txz")) return AU_FORMAT_XZ;
    if (!strcasecmp(dot, "bz2") || !strcasecmp(dot, "tbz") || !strcasecmp(dot, "tbz2"))
        return AU_FORMAT_BZIP2;
    if (!strcasecmp(dot, "cab")) return AU_FORMAT_CAB;
    if (!strcasecmp(dot, "iso")) return AU_FORMAT_ISO9660;
    if (!strcasecmp(dot, "lha") || !strcasecmp(dot, "lzh")) return AU_FORMAT_LHA;
    return AU_FORMAT_UNKNOWN;
}

static au_format magic(const unsigned char *head, size_t n) {
    if (n >= 4 && (!memcmp(head, "PK\003\004", 4) || !memcmp(head, "PK\005\006", 4) ||
                   !memcmp(head, "PK\007\010", 4))) return AU_FORMAT_ZIP;
    if (n >= 6 && !memcmp(head, "7z\xbc\xaf\x27\x1c", 6)) return AU_FORMAT_7ZIP;
    if (n >= 8 && !memcmp(head, "Rar!\x1a\x07\x01\x00", 8)) return AU_FORMAT_RAR5;
    if (n >= 7 && !memcmp(head, "Rar!\x1a\x07\x00", 7)) return AU_FORMAT_RAR;
    if (n >= 2 && !memcmp(head, "\x1f\x8b", 2)) return AU_FORMAT_GZIP;
    if (n >= 4 && !memcmp(head, "\x04\x22\x4d\x18", 4)) return AU_FORMAT_LZ4;
    if (n >= 4 && !memcmp(head, "\x28\xb5\x2f\xfd", 4)) return AU_FORMAT_ZSTD;
    if (n >= 6 && !memcmp(head, "\xfd" "7zXZ\x00", 6)) return AU_FORMAT_XZ;
    if (n >= 4 && !memcmp(head, "BZh", 3) && head[3] >= '1' && head[3] <= '9')
        return AU_FORMAT_BZIP2;
    if (n >= 8 && !memcmp(head, "MSCF\x00\x00\x00\x00", 8)) return AU_FORMAT_CAB;
    if (n >= 21 && head[2] == '-' && head[3] == 'l' && head[6] == '-' &&
        ((head[4] == 'h' && head[20] <= 3 && strchr("01234567d", head[5]) && head[5]) ||
         (head[4] == 'z' && head[20] == 0 && strchr("45s", head[5]) && head[5])))
        return AU_FORMAT_LHA;
    if (n >= 512 && !memcmp(head + 257, "ustar", 5)) return AU_FORMAT_TAR;
    return AU_FORMAT_UNKNOWN;
}

static unsigned filter_code(au_format format) {
    switch (format) {
    case AU_FORMAT_GZIP: return ARCHIVE_FILTER_GZIP;
    case AU_FORMAT_LZ4: return ARCHIVE_FILTER_LZ4;
    case AU_FORMAT_ZSTD: return ARCHIVE_FILTER_ZSTD;
    case AU_FORMAT_XZ: return ARCHIVE_FILTER_XZ;
    case AU_FORMAT_BZIP2: return ARCHIVE_FILTER_BZIP2;
    default: return ARCHIVE_FILTER_NONE;
    }
}

static au_format container_format(int format) {
    switch (format & ARCHIVE_FORMAT_BASE_MASK) {
    case ARCHIVE_FORMAT_ZIP: return AU_FORMAT_ZIP;
    case ARCHIVE_FORMAT_TAR: return AU_FORMAT_TAR;
    case ARCHIVE_FORMAT_7ZIP: return AU_FORMAT_7ZIP;
    case ARCHIVE_FORMAT_RAR: return AU_FORMAT_RAR;
    case ARCHIVE_FORMAT_RAR_V5: return AU_FORMAT_RAR5;
    case ARCHIVE_FORMAT_CAB: return AU_FORMAT_CAB;
    case ARCHIVE_FORMAT_ISO9660: return AU_FORMAT_ISO9660;
    case ARCHIVE_FORMAT_LHA: return AU_FORMAT_LHA;
    default: return AU_FORMAT_UNKNOWN;
    }
}

static au_status decoder_error(reader *state, au_status fallback) {
    if (state->input_error != AU_OK) return state->input_error;
    if (au_cancelled(&state->options)) return AU_CANCELLED;
    const char *message = archive_error_string(state->handle);
    if (archive_errno(state->handle) == ENOMEM) return AU_NOMEM;
    if (message) {
        if (strstr(message, "Incorrect passphrase") || strstr(message, "incorrect passphrase"))
            return AU_BAD_PASSPHRASE;
        if (strstr(message, "Passphrase required"))
            return AU_ENCRYPTED;
        if (strstr(message, "Decryption is unsupported") ||
            strstr(message, "encryption support unavailable") ||
            (strstr(message, "encrypted") && strstr(message, "not supported")) ||
            strstr(message, "Encrypted file is unsupported"))
            return AU_UNSUPPORTED_ENCRYPTION;
    }
    return fallback;
}

static int read_header(reader *state, struct archive_entry **entry) {
    locale_t previous = state->locale ? uselocale(state->locale) : (locale_t)0;
    int result = archive_read_next_header(state->handle, entry);
    if (previous) uselocale(previous);
    return result;
}

static char *stream_name(const char *hint, au_format filter) {
    const char *base = hint ? strrchr(hint, '/') : NULL;
    base = base ? base + 1 : hint;
    if (!base || !*base || strchr(base, '\\') || strchr(base, ':') || !au_valid_utf8(base))
        return strdup("data");
    const char *dot = strrchr(base, '.');
    size_t length = dot && dot != base && extension(base) == filter ? (size_t)(dot - base) :
                                                                    strlen(base);
    if (!length || length > NAME_LIMIT || (length == 1 && base[0] == '.') ||
        (length == 2 && !memcmp(base, "..", 2))) return strdup("data");
    if (length == strlen(base)) {
        char *name = malloc(length + sizeof(".out"));
        if (name) {
            memcpy(name, base, length);
            memcpy(name + length, ".out", sizeof(".out"));
        }
        return name;
    }
    return strndup(base, length);
}

static void close_reader(void *data) {
    reader *state = data;
    if (!state) return;
    if (state->handle) archive_read_free(state->handle);
    if (state->locale) freelocale(state->locale);
    aether_unzip_source_close(state->source);
    free(state->volumes);
    free(state->stream_name);
    free(state);
}

static int enable_formats(reader *state, au_format candidate, int filter) {
    struct archive *handle = state->handle;
    if (filter != ARCHIVE_FILTER_NONE) {
        /* Explicitly append one filter. Never auto-unroll nested compression. */
        if (archive_read_append_filter(handle, filter) != ARCHIVE_OK ||
            archive_read_support_format_raw(handle) != ARCHIVE_OK ||
            archive_read_support_format_empty(handle) != ARCHIVE_OK) return ARCHIVE_FATAL;
        return archive_read_support_format_tar(handle);
    }
    switch (candidate) {
    case AU_FORMAT_ZIP: return archive_read_support_format_zip_seekable(handle);
    case AU_FORMAT_7ZIP: return archive_read_support_format_7zip(handle);
    case AU_FORMAT_RAR: return archive_read_support_format_rar(handle);
    case AU_FORMAT_RAR5: return archive_read_support_format_rar5(handle);
    case AU_FORMAT_CAB: return archive_read_support_format_cab(handle);
    case AU_FORMAT_ISO9660: return archive_read_support_format_iso9660(handle);
    case AU_FORMAT_LHA: return archive_read_support_format_lha(handle);
    case AU_FORMAT_UNKNOWN:
        /* A self-extracting ZIP can have any prefix. The seekable reader
         * can verify its central directory without interpreting that prefix. */
        if (archive_read_support_format_zip_seekable(handle) != ARCHIVE_OK)
            return ARCHIVE_FATAL;
        return archive_read_support_format_tar(handle);
    default: return archive_read_support_format_tar(handle);
    }
}

static au_status probe(au_source *source, const char *hint, const char *passphrase,
                       const au_options *options, au_probe_result *info, void **output) {
    unsigned char header[512];
    size_t n;
    au_status status = aether_unzip_source_read_at(source, 0, header, sizeof(header), &n);
    if (status != AU_OK) return status;
    info->candidate = magic(header, n);
    if (!info->candidate) {
        /* ISO 9660 volume descriptors begin at logical sector 16. */
        status = aether_unzip_source_read_at(source, 16 * 2048 + 1, header, 5, &n);
        if (status != AU_OK) return status;
        if (n == 5 && !memcmp(header, "CD001", 5)) info->candidate = AU_FORMAT_ISO9660;
    }
    if (!info->extension_hint) info->extension_hint = extension(hint);
    if (info->candidate) info->evidence |= AU_EVIDENCE_MAGIC;
    if (info->extension_hint) info->evidence |= AU_EVIDENCE_EXTENSION;

    reader *state = calloc(1, sizeof(*state));
    if (!state) return AU_NOMEM;
    state->options = *options;
    state->source = source;
    au_source_retain(source);
    aether_unzip_source_length(source, &state->length);
    if (state->length > INT64_MAX) {
        close_reader(state);
        return AU_LIMIT;
    }
    state->locale = newlocale(LC_CTYPE_MASK, "C.UTF-8", NULL);
    if (!state->locale) state->locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    state->handle = archive_read_new();
    if (!state->handle) {
        close_reader(state);
        return AU_NOMEM;
    }

    int filter = (int)filter_code(info->candidate);
    int result = enable_formats(state, info->candidate, filter);
    if (result != ARCHIVE_OK) {
        close_reader(state);
        return AU_UNSUPPORTED;
    }
    if (passphrase && (info->candidate == AU_FORMAT_ZIP || info->candidate == AU_FORMAT_UNKNOWN) &&
        archive_read_add_passphrase(state->handle, passphrase) != ARCHIVE_OK) {
        status = decoder_error(state, AU_INVALID);
        close_reader(state);
        return status;
    }

    archive_read_set_seek_callback(state->handle, seek_input);
    archive_read_set_skip_callback(state->handle, skip_input);
    archive_read_set_read_callback(state->handle, pull);
    status = set_input(state, info->candidate);
    if (status != AU_OK) {
        close_reader(state);
        return status;
    }
    result = archive_read_open1(state->handle);
    if (result == ARCHIVE_OK) result = read_header(state, &state->pending);
    state->format = container_format(archive_format(state->handle));
    state->raw = filter != ARCHIVE_FILTER_NONE && state->format == AU_FORMAT_UNKNOWN;
    if (state->raw) state->format = info->candidate;
    /* The seekable ZIP bidder recognizes an empty EOCD, but may leave format unset at EOF. */
    if (!state->format && result == ARCHIVE_EOF && info->candidate == AU_FORMAT_ZIP)
        state->format = AU_FORMAT_ZIP;
    if ((result != ARCHIVE_OK && result != ARCHIVE_EOF) || !state->format) {
        status = decoder_error(state, info->candidate || state->format
                                        ? AU_CORRUPT : AU_UNKNOWN_FORMAT);
        close_reader(state);
        return status;
    }
    if (state->raw) {
        state->stream_name = stream_name(hint, info->candidate);
        if (!state->stream_name) {
            close_reader(state);
            return AU_NOMEM;
        }
    }
    state->first = result == ARCHIVE_OK || state->raw ? 1 : -1;
    info->format = state->format;
    info->filter = filter != ARCHIVE_FILTER_NONE ? info->candidate : AU_FORMAT_UNKNOWN;
    info->kind = state->raw ? AU_KIND_STREAM : AU_KIND_CONTAINER;
    info->evidence |= AU_EVIDENCE_STRUCTURE;
    info->capabilities = BASE_CAPABILITIES | AU_REQUIRES_SEEKABLE_SOURCE;
    if (state->format == AU_FORMAT_ZIP)
        info->capabilities |= AU_SUPPORTS_ENCRYPTION;
    if (state->format == AU_FORMAT_ZIP || state->format == AU_FORMAT_7ZIP ||
        state->format == AU_FORMAT_RAR || state->format == AU_FORMAT_RAR5)
        info->capabilities |= AU_SUPPORTS_MULTIVOLUME;
    *output = state;
    return AU_OK;
}

static au_status next(void *data, au_entry *out) {
    reader *state = data;
    if (state->first < 0 || (!state->first && state->raw)) return AU_END;
    struct archive_entry *entry = NULL;
    if (state->first) {
        entry = state->pending;
        state->first = 0;
    } else {
        int result = read_header(state, &entry);
        if (result == ARCHIVE_EOF) return AU_END;
        if (result != ARCHIVE_OK) return decoder_error(state, AU_CORRUPT);
    }

    if (state->raw) {
        out->name = state->stream_name;
        out->kind = AU_ENTRY_FILE;
        out->size_known = entry && archive_format(state->handle) == ARCHIVE_FORMAT_RAW ? 0 : 1;
    } else {
        locale_t previous = state->locale ? uselocale(state->locale) : (locale_t)0;
        out->name = archive_entry_pathname_utf8(entry);
        if (!out->name) out->name = archive_entry_pathname(entry);
        if (previous) uselocale(previous);
        if (!out->name || !au_valid_utf8(out->name)) return AU_CORRUPT;
        switch (archive_entry_filetype(entry)) {
        case AE_IFREG: out->kind = AU_ENTRY_FILE; break;
        case AE_IFDIR: out->kind = AU_ENTRY_DIRECTORY; break;
        default: out->kind = AU_ENTRY_OTHER; break;
        }
        if (archive_entry_hardlink(entry) || archive_entry_symlink(entry))
            out->kind = AU_ENTRY_OTHER;
        out->encrypted = archive_entry_is_encrypted(entry) > 0;
        out->size_known = archive_entry_size_is_set(entry) != 0;
        if (out->size_known && archive_entry_size(entry) < 0) return AU_CORRUPT;
        out->size = out->size_known ? (uint64_t)archive_entry_size(entry) : 0;
    }
    out->name_length = strnlen(out->name, NAME_LIMIT + 1);
    return out->name_length > NAME_LIMIT ? AU_LIMIT : AU_OK;
}

static au_status read_data(void *data, void *buffer, size_t size, size_t *n) {
    reader *state = data;
    *n = 0;
    if (state->raw && archive_format(state->handle) == ARCHIVE_FORMAT_EMPTY) return AU_OK;
    la_ssize_t result = archive_read_data(state->handle, buffer, size);
    if (result < 0) return decoder_error(state, AU_CORRUPT);
    *n = (size_t)result;
    return AU_OK;
}

static au_status skip_data(void *data, int *skipped) {
    reader *state = data;
    *skipped = state->format == AU_FORMAT_ZIP || state->raw;
    if (*skipped && !state->raw && archive_read_data_skip(state->handle) != ARCHIVE_OK)
        return decoder_error(state, AU_CORRUPT);
    return AU_OK;
}

static const au_format supported[] = { AU_FORMAT_ZIP, AU_FORMAT_TAR, AU_FORMAT_7ZIP,
    AU_FORMAT_RAR, AU_FORMAT_RAR5, AU_FORMAT_GZIP, AU_FORMAT_LZ4, AU_FORMAT_ZSTD,
    AU_FORMAT_XZ, AU_FORMAT_BZIP2, AU_FORMAT_CAB, AU_FORMAT_ISO9660, AU_FORMAT_LHA };

const au_driver au_libarchive_driver = {
    .info = { sizeof(au_driver_info), 1, "libarchive",
              BASE_CAPABILITIES | AU_REQUIRES_SEEKABLE_SOURCE | AU_SUPPORTS_ENCRYPTION |
              AU_SUPPORTS_MULTIVOLUME,
              sizeof(supported) / sizeof(supported[0]), supported },
    .probe = probe, .next = next, .read = read_data, .skip = skip_data, .close = close_reader
};
