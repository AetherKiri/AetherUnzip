#include <aetherunzip/api.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); \
                                     exit(1); } } while (0)

static const char message[] = "AetherUnzip fixture\n";
static const char legacy_message[] = "                          file 1 contents\nhello\nhello\nhello\n";
static int cwd;
static char work[] = "/tmp/aetherunzip-test.XXXXXX";
static au_context *context;

static void contents(const char *path, const char *expected) {
    FILE *file = fopen(path, "rb");
    REQUIRE(file);
    char bytes[128];
    size_t n = fread(bytes, 1, sizeof(bytes), file);
    REQUIRE(fclose(file) == 0);
    REQUIRE(n == strlen(expected) && !memcmp(bytes, expected, n));
}

static void content_hash(const char *path, uint64_t expected_length, uint64_t expected_hash) {
    FILE *file = fopen(path, "rb");
    REQUIRE(file);
    uint64_t length = 0, hash = UINT64_C(14695981039346656037);
    unsigned char bytes[4096];
    size_t n;
    while ((n = fread(bytes, 1, sizeof(bytes), file))) {
        length += n;
        for (size_t i = 0; i < n; ++i) hash = (hash ^ bytes[i]) * UINT64_C(1099511628211);
    }
    REQUIRE(!ferror(file));
    REQUIRE(fclose(file) == 0);
    REQUIRE(length == expected_length && hash == expected_hash);
}

static void independent_volumes(void);

static au_source *fixture(const char *name) {
    char path[256];
    snprintf(path, sizeof(path), "fixtures/%s", name);
    au_source *source = NULL;
    REQUIRE(aether_unzip_source_file(path, &source) == AU_OK);
    return source;
}

static const char *directory(const char *name) {
    static char path[512];
    snprintf(path, sizeof(path), "%s/%s", work, name);
    REQUIRE(mkdir(path, 0700) == 0);
    return path;
}

static void remove_tree(int parent, const char *name) {
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) { REQUIRE(unlinkat(parent, name, 0) == 0); return; }
    DIR *dir = fdopendir(fd);
    REQUIRE(dir);
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, ".."))
            remove_tree(fd, entry->d_name);
    }
    REQUIRE(closedir(dir) == 0);
    REQUIRE(unlinkat(parent, name, AT_REMOVEDIR) == 0);
}

static void no_output(const char *path) {
    DIR *dir = opendir(path);
    REQUIRE(dir);
    struct dirent *entry;
    while ((entry = readdir(dir)))
        REQUIRE(!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."));
    REQUIRE(closedir(dir) == 0);
}

typedef struct {
    unsigned char bytes[1024];
    size_t length;
    size_t cursor;
    unsigned closed;
    unsigned flushed;
    int failing;
} callback_buffer;

static au_status read_callback_at(void *user, uint64_t offset, void *buffer, size_t capacity,
                                 size_t *count) {
    callback_buffer *state = user;
    if (state->failing) return AU_IO;
    *count = 0;
    if (offset >= state->length) return AU_OK;
    size_t remaining = state->length - (size_t)offset;
    if (capacity > remaining) capacity = remaining;
    if (capacity > 13) capacity = 13;
    memcpy(buffer, state->bytes + offset, capacity);
    *count = capacity;
    return AU_OK;
}

static au_status read_callback(void *user, void *buffer, size_t capacity, size_t *count) {
    callback_buffer *state = user;
    au_status status = read_callback_at(user, state->cursor, buffer, capacity, count);
    if (status == AU_OK) state->cursor += *count;
    return status;
}

static void close_callback_source(void *user) { ++((callback_buffer *)user)->closed; }

static au_status write_callback(void *user, const void *data, size_t size) {
    callback_buffer *state = user;
    if (state->failing) return AU_IO;
    if (size > sizeof(state->bytes) - state->length) return AU_LIMIT;
    memcpy(state->bytes + state->length, data, size);
    state->length += size;
    return AU_OK;
}

static au_status flush_callback(void *user) {
    ++((callback_buffer *)user)->flushed;
    return AU_OK;
}

static au_status close_callback_sink(void *user) {
    close_callback_source(user);
    return ((callback_buffer *)user)->failing ? AU_IO : AU_OK;
}

static void callback_io(void) {
    callback_buffer input = {0};
    FILE *zip = fopen("fixtures/sample.zip", "rb");
    REQUIRE(zip);
    input.length = fread(input.bytes, 1, sizeof(input.bytes), zip);
    REQUIRE(input.length > 13 && feof(zip) && fclose(zip) == 0);

    au_source_callbacks callbacks = {sizeof(callbacks), read_callback, NULL, close_callback_source};
    au_source *source = NULL, *slice = NULL;
    au_probe_result probe = {.struct_size = sizeof(probe)};
    size_t count;
    uint64_t length;
    unsigned char bytes[32];
    REQUIRE(aether_unzip_source_callback(&callbacks, &input, NULL, &source) == AU_OK);
    REQUIRE(aether_unzip_source_capabilities(source) == AU_IO_SEQUENTIAL);
    REQUIRE(aether_unzip_source_length(source, &length) == AU_UNSUPPORTED);
    REQUIRE(aether_unzip_source_read_at(source, 0, bytes, sizeof(bytes), &count) == AU_UNSUPPORTED);
    REQUIRE(aether_unzip_probe(context, source, "sample.zip", &probe) == AU_UNSUPPORTED);
    REQUIRE(aether_unzip_source_read(source, bytes, sizeof(bytes), &count) == AU_OK && count == 13);
    REQUIRE(!memcmp(bytes, input.bytes, count));
    input.failing = 1;
    REQUIRE(aether_unzip_source_read(source, bytes, sizeof(bytes), &count) == AU_IO && count == 0);
    aether_unzip_source_close(source);
    REQUIRE(input.closed == 1);

    input.failing = 0;
    input.cursor = 0;
    callbacks.read_at = read_callback_at;
    length = input.length;
    REQUIRE(aether_unzip_source_callback(&callbacks, &input, &length, &source) == AU_OK);
    REQUIRE(aether_unzip_source_capabilities(source) == (AU_IO_SEQUENTIAL | AU_IO_RANDOM | AU_IO_LENGTH));
    REQUIRE(aether_unzip_probe(context, source, NULL, &probe) == AU_OK);
    REQUIRE(input.cursor == 0);
    au_archive *archive = NULL;
    REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_OK);
    const au_entry *entry = NULL;
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
    REQUIRE(aether_unzip_archive_read(archive, bytes, sizeof(bytes), &count) == AU_OK);
    REQUIRE(count == sizeof(message) - 1 && !memcmp(bytes, message, count));
    aether_unzip_archive_close(archive);
    REQUIRE(aether_unzip_source_slice(source, 0, sizeof(bytes), &slice) == AU_OK);
    aether_unzip_source_close(source);
    REQUIRE(input.closed == 1);
    REQUIRE(aether_unzip_source_read(slice, bytes, sizeof(bytes), &count) == AU_OK && count == sizeof(bytes));
    REQUIRE(!memcmp(bytes, input.bytes, count));
    aether_unzip_source_close(slice);
    REQUIRE(input.closed == 2);

    callback_buffer output = {0};
    au_sink_callbacks writes = {sizeof(writes), write_callback, NULL, flush_callback, close_callback_sink};
    au_sink *sink = NULL;
    REQUIRE(aether_unzip_sink_callback(&writes, &output, &sink) == AU_OK);
    REQUIRE(aether_unzip_sink_capabilities(sink) == AU_IO_SEQUENTIAL);
    REQUIRE(aether_unzip_sink_write_at(sink, 0, message, sizeof(message)) == AU_UNSUPPORTED);
    REQUIRE(aether_unzip_sink_write(sink, message, sizeof(message)) == AU_OK);
    REQUIRE(output.length == sizeof(message) && !memcmp(output.bytes, message, sizeof(message)));
    REQUIRE(aether_unzip_sink_flush(sink) == AU_OK && output.flushed == 1);
    output.failing = 1;
    REQUIRE(aether_unzip_sink_write(sink, "x", 1) == AU_IO);
    REQUIRE(aether_unzip_sink_close(sink) == AU_IO && output.closed == 1);
}

static void io_test(void) {
    callback_io();
    REQUIRE(aether_unzip_abi_version() == AETHER_UNZIP_ABI_VERSION);
    REQUIRE(!strcmp(aether_unzip_version(), "0.1.0"));
    REQUIRE(aether_unzip_driver_count(context) == 3);
    REQUIRE(!strcmp(aether_unzip_driver_at(context, 0)->id, "xp3"));
    const au_driver_info *driver = aether_unzip_driver_at(context, 1);
    REQUIRE(driver && driver->version == 1 && driver->format_count == 13);
    REQUIRE(!strcmp(aether_unzip_driver_at(context, 2)->id, "brotli"));
    REQUIRE(!aether_unzip_driver_at(context, 3));

    au_source *source = NULL, *slice = NULL, *inner = NULL;
    char bytes[16] = "0123456789";
    size_t n;
    REQUIRE(aether_unzip_source_memory(bytes, 10, &source) == AU_OK);
    memset(bytes, 0, sizeof(bytes));
    REQUIRE(aether_unzip_source_slice(source, 3, 8, &slice) == AU_INVALID);
    REQUIRE(aether_unzip_source_slice(source, 3, 7, &slice) == AU_OK);
    REQUIRE(aether_unzip_source_slice(slice, 1, 4, &inner) == AU_OK);
    aether_unzip_source_close(source);
    aether_unzip_source_close(slice);
    REQUIRE(aether_unzip_source_read(inner, bytes, 2, &n) == AU_OK && n == 2);
    REQUIRE(aether_unzip_source_read(inner, bytes + 2, 12, &n) == AU_OK && n == 2);
    REQUIRE(!memcmp(bytes, "4567", 4));
    REQUIRE(aether_unzip_source_read(inner, bytes, 2, &n) == AU_OK && n == 0);
    aether_unzip_source_close(inner);

    au_source *segments[3] = {NULL}, *combined = NULL;
    REQUIRE(aether_unzip_source_memory("12", 2, &segments[0]) == AU_OK);
    REQUIRE(aether_unzip_source_memory(NULL, 0, &segments[1]) == AU_OK);
    REQUIRE(aether_unzip_source_memory("345", 3, &segments[2]) == AU_OK);
    REQUIRE(aether_unzip_source_concat(segments, 3, &combined) == AU_OK);
    for (size_t i = 0; i < 3; ++i) aether_unzip_source_close(segments[i]);
    REQUIRE(aether_unzip_source_slice(combined, 1, 3, &slice) == AU_OK);
    aether_unzip_source_close(combined);
    REQUIRE(aether_unzip_source_read(slice, bytes, sizeof(bytes), &n) == AU_OK && n == 3);
    REQUIRE(!memcmp(bytes, "234", 3));
    aether_unzip_source_close(slice);

    au_sink *sink = NULL;
    const void *view;
    REQUIRE(aether_unzip_sink_memory(7, &sink) == AU_OK);
    REQUIRE(aether_unzip_sink_write(sink, "ab", 2) == AU_OK);
    REQUIRE(aether_unzip_sink_write_at(sink, 4, "c", 1) == AU_OK);
    REQUIRE(aether_unzip_sink_write_at(sink, 6, "cd", 2) == AU_LIMIT);
    REQUIRE(aether_unzip_sink_memory_view(sink, &view, &n) == AU_OK && n == 5);
    REQUIRE(!memcmp(view, "ab\0\0c", 5));
    REQUIRE(aether_unzip_sink_close(sink) == AU_OK);

    char path[512];
    snprintf(path, sizeof(path), "%s/file", work);
    REQUIRE(aether_unzip_sink_file(path, &sink) == AU_OK);
    REQUIRE(aether_unzip_sink_write(sink, "text", 4) == AU_OK);
    REQUIRE(aether_unzip_sink_write_at(sink, 0, "T", 1) == AU_OK);
    REQUIRE(aether_unzip_sink_flush(sink) == AU_OK);
    REQUIRE(aether_unzip_sink_close(sink) == AU_OK);
    contents(path, "Text");
    REQUIRE(aether_unzip_source_file(path, &source) == AU_OK);
    REQUIRE(aether_unzip_source_read_at(source, 1, bytes, sizeof(bytes), &n) == AU_OK && n == 3);
    REQUIRE(!memcmp(bytes, "ext", 3));
    aether_unzip_source_close(source);
    REQUIRE(aether_unzip_source_file("/does-not-exist-aether", &source) == AU_IO);
}

static void xp3_tests(void) {
    au_source *source = fixture("sample.xp3");
    au_probe_result result = {.struct_size = sizeof(result)};
    REQUIRE(aether_unzip_probe(context, source, "disguised.bin", &result) == AU_OK);
    REQUIRE(result.format == AU_FORMAT_XP3 && result.kind == AU_KIND_CONTAINER);
    REQUIRE(result.evidence == (AU_EVIDENCE_MAGIC | AU_EVIDENCE_STRUCTURE));
    REQUIRE((result.capabilities & (AU_CAN_SEEK | AU_SUPPORTS_ENCRYPTION)) == 0);
    au_options options = aether_unzip_options_default();
    options.max_entries = 1;
    au_archive *archive = NULL;
    REQUIRE(aether_unzip_archive_open(context, source, NULL, &options, &archive) == AU_LIMIT);
    REQUIRE(!archive);

    au_resource_mount *mount = NULL;
    au_resource_file *file = NULL;
    REQUIRE(aether_unzip_resource_mount(context, source, NULL, NULL, &mount) == AU_OK);
    REQUIRE(aether_unzip_resource_build_index(mount, 4096) == AU_OK);
    REQUIRE(aether_unzip_resource_open_path(mount, "docs/样本📦.txt", &file) == AU_OK);
    aether_unzip_resource_unmount(mount);
    unsigned char bytes[113];
    size_t count, total = 0;
    const char prefix[] = "Stored prefix\n";
    const char line[] = "XP3 resource line\n";
    do {
        REQUIRE(aether_unzip_resource_read(file, bytes, sizeof(bytes), &count) == AU_OK);
        for (size_t i = 0; i < count; ++i, ++total) {
            size_t head = sizeof(prefix) - 1;
            REQUIRE(bytes[i] == (unsigned char)(total < head ? prefix[total]
                                                            : line[(total - head) % (sizeof(line) - 1)]));
        }
    } while (count);
    REQUIRE(total == sizeof(prefix) - 1 + 12000 * (sizeof(line) - 1));
    aether_unzip_resource_close(file);
    const char *output = directory("xp3-stream-limited");
    options = aether_unzip_options_default();
    options.max_entry_bytes = 100000;
    const uint64_t second = 1;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, &second, 1, &options) == AU_LIMIT);
    aether_unzip_source_close(source);

    source = fixture("xp3-upstream.xp3");
    REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_OK);
    aether_unzip_source_close(source);
    const au_entry *entry = NULL;
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
    REQUIRE(!strcmp(entry->name, "notes.txt"));
    REQUIRE(aether_unzip_archive_read(archive, bytes, sizeof(bytes), &count) == AU_OK);
    REQUIRE(count == sizeof(message) - 1 && !memcmp(bytes, message, count));
    REQUIRE(aether_unzip_archive_read(archive, bytes, sizeof(bytes), &count) == AU_OK && !count);
    aether_unzip_archive_close(archive);

    source = fixture("xp3-protected.xp3");
    REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_OK);
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK && entry->kind == AU_ENTRY_OTHER);
    REQUIRE(aether_unzip_archive_read(archive, bytes, sizeof(bytes), &count) == AU_UNSUPPORTED);
    aether_unzip_archive_close(archive);
    output = directory("xp3-public");
    REQUIRE(aether_unzip_extract(context, source, NULL, output, &second, 1, NULL) == AU_OK);
    char path[512];
    snprintf(path, sizeof(path), "%s/notes.txt", output);
    contents(path, message);
    aether_unzip_source_close(source);

    const char *malformed[] = {"xp3-truncated.xp3", "xp3-index-cycle.xp3"};
    for (size_t i = 0; i < sizeof(malformed) / sizeof(*malformed); ++i) {
        source = fixture(malformed[i]);
        REQUIRE(aether_unzip_probe(context, source, NULL, &result) == AU_CORRUPT);
        REQUIRE(result.candidate == AU_FORMAT_XP3 && result.evidence == AU_EVIDENCE_MAGIC);
        aether_unzip_source_close(source);
    }
    source = fixture("xp3-checksum.xp3");
    output = directory("xp3-checksum");
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_CORRUPT);
    no_output(output);
    aether_unzip_source_close(source);
    source = fixture("xp3-unsafe.xp3");
    output = directory("xp3-unsafe");
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_UNSAFE_PATH);
    no_output(output);
    aether_unzip_source_close(source);
    source = fixture("sample.zip");
    REQUIRE(aether_unzip_probe(context, source, "misleading.xp3", &result) == AU_OK);
    REQUIRE(result.format == AU_FORMAT_ZIP && result.extension_hint == AU_FORMAT_XP3);
    aether_unzip_source_close(source);
}

static void format_tests(void) {
    xp3_tests();
    independent_volumes();
    const struct { const char *name, *leaf; au_format format, filter; uint64_t index;
                   const char *expected; } cases[] = {
        {"sample.zip", "notes.txt", AU_FORMAT_ZIP, 0, 0, message},
        {"prefixed-zip.bin", "notes.txt", AU_FORMAT_ZIP, 0, 0, message},
        {"small-zip64.zip", "notes.txt", AU_FORMAT_ZIP, 0, 0, message},
        {"sample.7z", "notes.txt", AU_FORMAT_7ZIP, 0, 0, message},
        {"test_read_format_rar.rar", "test.txt", AU_FORMAT_RAR, 0, 0, "test text document\r\n"},
        {"test_read_format_rar5_stored.rar", "helloworld.txt", AU_FORMAT_RAR5, 0, 0,
         "hello libarchive test suite!\n"},
        {"sample.tar", "notes.txt", AU_FORMAT_TAR, 0, 1, message},
        {"sample.tar.gz", "notes.txt", AU_FORMAT_TAR, AU_FORMAT_GZIP, 1, message},
        {"sample.tar.lz4", "notes.txt", AU_FORMAT_TAR, AU_FORMAT_LZ4, 1, message},
        {"sample.tar.zst", "notes.txt", AU_FORMAT_TAR, AU_FORMAT_ZSTD, 1, message},
        {"sample.tar.xz", "notes.txt", AU_FORMAT_TAR, AU_FORMAT_XZ, 1, message},
        {"sample.tar.bz2", "notes.txt", AU_FORMAT_TAR, AU_FORMAT_BZIP2, 1, message},
        {"sample.iso", "notes.txt", AU_FORMAT_ISO9660, 0, 1, message},
        {"test_read_format_cab_2.cab", "dir1/file1", AU_FORMAT_CAB, 0, 2, legacy_message},
        {"test_read_format_cab_3.cab", "dir1/file1", AU_FORMAT_CAB, 0, 2, legacy_message},
        {"test_read_format_lha_lh7.lzh", "file1", AU_FORMAT_LHA, 0, 4, legacy_message},
        {"notes.gz", "notes", AU_FORMAT_GZIP, AU_FORMAT_GZIP, 0, message},
        {"members.gz", "members", AU_FORMAT_GZIP, AU_FORMAT_GZIP, 0,
         "AetherUnzip fixture\nAdditional member\n"},
        {"notes.lz4", "notes", AU_FORMAT_LZ4, AU_FORMAT_LZ4, 0, message},
        {"notes.zst", "notes", AU_FORMAT_ZSTD, AU_FORMAT_ZSTD, 0, message},
        {"notes.xz", "notes", AU_FORMAT_XZ, AU_FORMAT_XZ, 0, message},
        {"notes.bz2", "notes", AU_FORMAT_BZIP2, AU_FORMAT_BZIP2, 0, message},
        {"notes.br", "notes", AU_FORMAT_BROTLI, AU_FORMAT_BROTLI, 0, message},
        {"empty.br", "empty", AU_FORMAT_BROTLI, AU_FORMAT_BROTLI, 0, ""},
        {"xp3-raw.xp3", "notes.txt", AU_FORMAT_XP3, 0, 0, message},
        {"xp3-wrapped.bin", "notes.txt", AU_FORMAT_XP3, 0, 0, message},
        {"sample.xp3", "empty.txt", AU_FORMAT_XP3, 0, 2, ""},
        {"empty.gz", "empty", AU_FORMAT_GZIP, AU_FORMAT_GZIP, 0, ""}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        printf("Checking %s\n", cases[i].name);
        const char *output = directory(cases[i].name);
        au_source *source = fixture(cases[i].name);
        au_probe_result result = {.struct_size = sizeof(result)};
        int brotli = cases[i].format == AU_FORMAT_BROTLI;
        REQUIRE(aether_unzip_probe(context, source, brotli ? cases[i].name : "wrong.dat",
                                   &result) == AU_OK);
        REQUIRE(result.format == cases[i].format && result.filter == cases[i].filter);
        REQUIRE(result.kind == (result.filter == result.format ? AU_KIND_STREAM : AU_KIND_CONTAINER));
        if (strcmp(cases[i].name, "prefixed-zip.bin") != 0)
            REQUIRE(result.evidence & (brotli ? AU_EVIDENCE_EXTENSION : AU_EVIDENCE_MAGIC));
        else
            REQUIRE(!(result.evidence & (AU_EVIDENCE_MAGIC | AU_EVIDENCE_EXTENSION)));
        REQUIRE(result.evidence & AU_EVIDENCE_STRUCTURE);
        REQUIRE(aether_unzip_extract(context, source, cases[i].name, output, &cases[i].index,
                                     1, NULL) == AU_OK);
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", output, cases[i].leaf);
        contents(path, cases[i].expected);
        aether_unzip_source_close(source);
    }

    const char *extensions[] = {"7z", "zip"};
    for (size_t i = 0; i < 2; ++i) {
        au_source *parts[3];
        char name[128];
        for (size_t part = 0; part < 3; ++part) {
            snprintf(name, sizeof(name), "volumes/sample.%s.%03zu", extensions[i], part + 1);
            parts[part] = fixture(name);
        }
        au_source *combined = NULL;
        REQUIRE(aether_unzip_source_concat(parts, 3, &combined) == AU_OK);
        for (size_t part = 0; part < 3; ++part) aether_unzip_source_close(parts[part]);
        snprintf(name, sizeof(name), "sample.%s", extensions[i]);
        char folder[128];
        snprintf(folder, sizeof(folder), "split-%s", extensions[i]);
        const char *target = directory(folder);
        REQUIRE(aether_unzip_extract(context, combined, name, target, NULL, 0, NULL) == AU_OK);
        aether_unzip_source_close(combined);
        char path[640];
        snprintf(path, sizeof(path), "%s/notes.txt", target);
        contents(path, "Known bytes for volume validation.\n");
    }

    au_source *source = fixture("sample.zip");
    au_probe_result zip = {.struct_size = sizeof(zip)};
    REQUIRE(aether_unzip_probe(context, source, "sample.br", &zip) == AU_OK);
    REQUIRE(zip.format == AU_FORMAT_ZIP);
    uint64_t length;
    REQUIRE(aether_unzip_source_length(source, &length) == AU_OK && length < 1000);
    unsigned char buffer[1008] = "wrapper";
    size_t n;
    REQUIRE(aether_unzip_source_read_at(source, 0, buffer + 8, (size_t)length, &n) == AU_OK);
    REQUIRE(n == length);
    aether_unzip_source_close(source);

    au_source *slice = NULL;
    REQUIRE(aether_unzip_source_memory(buffer, n + 8, &source) == AU_OK);
    REQUIRE(aether_unzip_source_slice(source, 8, n, &slice) == AU_OK);
    aether_unzip_source_close(source);
    au_resource_mount *mount = NULL;
    REQUIRE(aether_unzip_resource_mount(context, slice, "wrong.rar", NULL, &mount) == AU_OK);
    aether_unzip_source_close(slice);
    REQUIRE(aether_unzip_resource_info(mount)->extension_hint == AU_FORMAT_RAR);
    REQUIRE(aether_unzip_resource_info(mount)->format == AU_FORMAT_ZIP);
    const au_entry *entry;
    REQUIRE(aether_unzip_resource_next(mount, &entry) == AU_OK && entry->index == 0);
    REQUIRE(!strcmp(entry->name, "notes.txt"));
    REQUIRE(aether_unzip_resource_next(mount, &entry) == AU_OK && entry->index == 1);
    REQUIRE(aether_unzip_resource_next(mount, &entry) == AU_OK && entry->index == 2);
    REQUIRE(!strcmp(entry->name, "docs/空白.txt"));
    REQUIRE(aether_unzip_resource_next(mount, &entry) == AU_END);
    au_resource_file *file = NULL;
    REQUIRE(aether_unzip_resource_open(mount, 3, &file) == AU_NOT_FOUND);
    REQUIRE(aether_unzip_resource_open(mount, 0, &file) == AU_OK);
    aether_unzip_resource_unmount(mount);
    REQUIRE(aether_unzip_resource_file_capabilities(file) == (AU_IO_SEQUENTIAL | AU_IO_LENGTH));
    REQUIRE(aether_unzip_resource_read(file, buffer, sizeof(buffer), &n) == AU_OK);
    REQUIRE(n == strlen(message) && !memcmp(buffer, message, n));
    REQUIRE(aether_unzip_resource_read(file, buffer, sizeof(buffer), &n) == AU_OK && n == 0);
    aether_unzip_resource_close(file);

    source = fixture("empty.zip");
    au_archive *archive = NULL;
    REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_OK);
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_END);
    aether_unzip_archive_close(archive);
    aether_unzip_source_close(source);

    au_probe_result result = {.struct_size = sizeof(result)};
    REQUIRE(aether_unzip_source_memory("plain text", 10, &source) == AU_OK);
    REQUIRE(aether_unzip_probe(context, source, "misleading.zip", &result) == AU_UNKNOWN_FORMAT);
    REQUIRE(result.evidence == AU_EVIDENCE_EXTENSION && result.extension_hint == AU_FORMAT_ZIP);
    aether_unzip_source_close(source);
    REQUIRE(aether_unzip_source_memory("PK\003\004", 4, &source) == AU_OK);
    REQUIRE(aether_unzip_probe(context, source, NULL, &result) == AU_CORRUPT);
    REQUIRE(result.candidate == AU_FORMAT_ZIP && result.validation == AU_CORRUPT);
    aether_unzip_source_close(source);
}

static void profile_tests(void) {
    au_source *standard = fixture("sample.zip");
    uint64_t payload_size;
    REQUIRE(aether_unzip_source_length(standard, &payload_size) == AU_OK);
    aether_unzip_source_close(standard);
    au_source *wrapper = fixture("profile-box.bin");
    au_format_profile profile = {.struct_size = sizeof(profile), .format = AU_FORMAT_ZIP,
        .signature_offset = 2, .signature = "PKG1", .signature_size = 4, .payload_offset = 8,
        .payload_size = payload_size, .name_hint = "payload.zip"};
    au_archive *archive = NULL;
    au_source *payload = NULL;
    REQUIRE(aether_unzip_profile_open(context, wrapper, &profile, NULL, &payload, &archive) == AU_OK);
    const au_probe_result *info = aether_unzip_archive_info(archive);
    REQUIRE(info->format == AU_FORMAT_ZIP && (info->evidence & AU_EVIDENCE_STRUCTURE));
    const au_entry *entry;
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK && !strcmp(entry->name, "notes.txt"));
    aether_unzip_archive_close(archive);
    const char *target = directory("profile-output");
    REQUIRE(aether_unzip_extract(context, payload, profile.name_hint, target, NULL, 0, NULL) == AU_OK);
    char path[512];
    snprintf(path, sizeof(path), "%s/notes.txt", target);
    contents(path, message);
    REQUIRE(aether_unzip_source_length(payload, &payload_size) == AU_OK && payload_size == profile.payload_size);
    aether_unzip_source_close(payload);

    profile.format = AU_FORMAT_TAR;
    REQUIRE(aether_unzip_profile_open(context, wrapper, &profile, NULL, &payload, &archive) == AU_PROFILE_MISMATCH);
    REQUIRE(!payload && !archive);
    profile.format = AU_FORMAT_ZIP;
    profile.signature = "none";
    REQUIRE(aether_unzip_profile_slice(wrapper, &profile, &payload) == AU_PROFILE_MISMATCH);
    profile.signature = "PKG1";
    size_t expected_to_end = (size_t)profile.payload_size + strlen("Unrelated footer");
    profile.payload_size = UINT64_MAX;
    REQUIRE(aether_unzip_profile_slice(wrapper, &profile, &payload) == AU_PROFILE_MISMATCH);
    profile.payload_size = 0;
    REQUIRE(aether_unzip_profile_slice(wrapper, &profile, &payload) == AU_OK);
    aether_unzip_source_close(wrapper);
    REQUIRE(aether_unzip_source_length(payload, &payload_size) == AU_OK && payload_size == expected_to_end);
    aether_unzip_source_close(payload);
}

static void independent_volumes(void) {
    static const struct {
        const char *name;
        const char *parts[4];
        size_t count;
        au_format format;
        const char *first_checked;
        const char *text;
        const char *binary;
        uint64_t length, hash;
    } cases[] = {
        {"disk.zip", {"disk.z01", "disk.z02", "disk.zip"}, 3, AU_FORMAT_ZIP, "notes.txt",
         "Notes from the last ZIP disk.\n", "payload.bin", 135680, UINT64_C(0x56f86829e4077925)},
        {"small-disk64.zip", {"small-disk64.z01", "small-disk64.z02", "small-disk64.zip"}, 3,
         AU_FORMAT_ZIP, "second.txt", "Second ZIP64 disk\n", NULL, 0, 0},
        {"old.rar", {"old.part01.rar", "old.part02.rar", "old.part03.rar"}, 3, AU_FORMAT_RAR,
         NULL, NULL, "LibarchiveAddingTest.html", 20111, UINT64_C(0xa46dd6be00775a17)},
        {"new.rar", {"new.part01.rar", "new.part02.rar", "new.part03.rar", "new.part04.rar"},
         4, AU_FORMAT_RAR5, NULL, NULL, "elf-Linux-ARMv7-ls", 90808, UINT64_C(0xc1015e64d2d8626d)}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        au_source *parts[4];
        char path[640];
        for (size_t part = 0; part < cases[i].count; ++part) {
            snprintf(path, sizeof(path), "independent/%s", cases[i].parts[part]);
            parts[part] = fixture(path);
        }
        au_source *source = NULL;
        REQUIRE(aether_unzip_source_concat(parts, cases[i].count, &source) == AU_OK);
        const char *target = directory(cases[i].name);
        au_probe_result result = {.struct_size = sizeof(result)};
        REQUIRE(aether_unzip_probe(context, source, cases[i].name, &result) == AU_OK);
        REQUIRE(result.format == cases[i].format && (result.capabilities & AU_SUPPORTS_MULTIVOLUME));
        REQUIRE(aether_unzip_extract(context, source, cases[i].name, target, NULL, 0, NULL) == AU_OK);
        if (cases[i].text) {
            snprintf(path, sizeof(path), "%s/%s", target, cases[i].first_checked);
            contents(path, cases[i].text);
        }
        if (cases[i].binary) {
            snprintf(path, sizeof(path), "%s/%s", target, cases[i].binary);
            content_hash(path, cases[i].length, cases[i].hash);
        }
        aether_unzip_source_close(source);
        for (size_t part = 0; part < cases[i].count; ++part) aether_unzip_source_close(parts[part]);
    }
}

static int32_t cancelled(void *flag) { return *(int *)flag; }

static au_resource_mount *indexed_fixture(const char *name) {
    au_source *source = fixture(name);
    au_resource_mount *mount = NULL;
    REQUIRE(aether_unzip_resource_mount(context, source, name, NULL, &mount) == AU_OK);
    aether_unzip_source_close(source);
    REQUIRE(aether_unzip_resource_build_index(mount, 4096) == AU_OK);
    return mount;
}

static void composed_resources(void) {
    au_resource_mount *base = indexed_fixture("sample.zip");
    au_resource_mount *updates = indexed_fixture("resource-index.zip");
    au_resource_mount *patch = indexed_fixture("sample.xp3");
    au_resource_layer layers[] = {
        {sizeof(au_resource_layer), base, NULL},
        {sizeof(au_resource_layer), updates, "./"},
        {sizeof(au_resource_layer), patch, NULL},
        {sizeof(au_resource_layer), patch, "./assets/"},
    };
    au_resource_mount *view = NULL;
    au_options options = aether_unzip_options_default();
    options.max_entries = 1;
    REQUIRE(aether_unzip_resource_compose(layers, 4, AU_RESOURCE_STRICT, 4096, &options, &view) == AU_LIMIT);
    REQUIRE(aether_unzip_resource_compose(layers, 4, AU_RESOURCE_STRICT, 1, NULL, &view) == AU_LIMIT);
    layers[3].prefix = "../outside";
    REQUIRE(aether_unzip_resource_compose(layers, 4, AU_RESOURCE_STRICT, 4096, NULL, &view) == AU_UNSAFE_PATH);
    layers[3].prefix = "assets";
    options = aether_unzip_options_default();
    int cancel = 1;
    options.cancel = cancelled;
    options.user = &cancel;
    REQUIRE(aether_unzip_resource_compose(layers, 4, AU_RESOURCE_STRICT, 4096, &options, &view) == AU_CANCELLED);
    REQUIRE(!view);
    cancel = 0;
    REQUIRE(aether_unzip_resource_compose(layers, 4, AU_RESOURCE_STRICT, 4096, &options, &view) == AU_OK);
    REQUIRE(!aether_unzip_resource_info(view));
    au_source *combined = NULL;
    REQUIRE(aether_unzip_resource_source(view, &combined) == AU_UNSUPPORTED && !combined);
    const au_entry *entry = NULL;
    REQUIRE(aether_unzip_resource_lookup(view, "docs/report.txt", &entry) == AU_EXISTS && !entry);
    REQUIRE(aether_unzip_resource_lookup(view, "notes.txt", &entry) == AU_EXISTS && !entry);
    REQUIRE(aether_unzip_resource_lookup(view, "assets/notes.txt", &entry) == AU_OK);
    REQUIRE(!strcmp(entry->name, "assets/notes.txt"));
    au_resource_file *file = NULL;
    REQUIRE(aether_unzip_resource_open(view, entry->index, &file) == AU_OK);
    REQUIRE(!strcmp(aether_unzip_resource_file_entry(file)->name, "assets/notes.txt"));
    au_resource_directory *cursor = NULL;
    REQUIRE(aether_unzip_resource_directory_open(view, "docs", &cursor) == AU_OK);
    aether_unzip_resource_unmount(view);
    cancel = 1;
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_CANCELLED);
    cancel = 0;
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_OK);
    REQUIRE(!strcmp(entry->name, "docs/readme.txt"));
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_OK);
    REQUIRE(!strcmp(entry->name, "docs/regional") && entry->kind == AU_ENTRY_DIRECTORY);
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_EXISTS);
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_OK);
    REQUIRE(!strcmp(entry->name, "docs/样本📦.txt"));
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_OK);
    REQUIRE(!strcmp(entry->name, "docs/空白.txt"));
    REQUIRE(aether_unzip_resource_directory_next(cursor, &entry) == AU_END);
    aether_unzip_resource_directory_close(cursor);
    char bytes[64];
    size_t count;
    REQUIRE(aether_unzip_resource_read(file, bytes, sizeof(bytes), &count) == AU_OK);
    REQUIRE(count == strlen(message) && !memcmp(bytes, message, count));
    aether_unzip_resource_close(file);

    // The last layer's file replaces a different path payload in the lower layer.
    au_resource_mount *wrapped = indexed_fixture("nested.zip");
    au_resource_mount *replacement = indexed_fixture("composition-patch.zip");
    layers[0] = (au_resource_layer){sizeof(au_resource_layer), wrapped, "mixed"};
    layers[1] = (au_resource_layer){sizeof(au_resource_layer), replacement, "mixed"};
    REQUIRE(aether_unzip_resource_compose(layers, 2, AU_RESOURCE_PREFER_LAST, 4096, NULL, &view) == AU_OK);
    REQUIRE(aether_unzip_resource_lookup(view, "mixed", &entry) == AU_OK && entry->kind == AU_ENTRY_DIRECTORY);
    REQUIRE(aether_unzip_resource_open_path(view, "mixed/plain.txt", &file) == AU_OK);
    REQUIRE(aether_unzip_resource_read(file, bytes, sizeof(bytes), &count) == AU_OK);
    REQUIRE(count == 12 && !memcmp(bytes, "Patch bytes\n", count));
    aether_unzip_resource_close(file);
    REQUIRE(aether_unzip_resource_lookup(view, "mixed/packages", &entry) == AU_EXISTS);
    REQUIRE(aether_unzip_resource_lookup(view, "mixed/packages/内层.bin", &entry) == AU_EXISTS);
    au_resource_layer group = {sizeof(group), view, "group"};
    au_resource_mount *subtree = NULL;
    REQUIRE(aether_unzip_resource_compose(&group, 1, AU_RESOURCE_STRICT, 4096, NULL, &subtree) == AU_OK);
    aether_unzip_resource_unmount(view);
    aether_unzip_resource_unmount(wrapped);
    aether_unzip_resource_unmount(replacement);
    aether_unzip_resource_unmount(base);
    aether_unzip_resource_unmount(updates);
    aether_unzip_resource_unmount(patch);
    REQUIRE(aether_unzip_resource_next(subtree, &entry) == AU_OK && !strcmp(entry->name, "group"));
    REQUIRE(aether_unzip_resource_next(subtree, &entry) == AU_OK && !strcmp(entry->name, "group/mixed"));
    const char *scratch = directory("composed-nested");
    au_resource_mount *nested = NULL;
    au_nested_limits limits = {sizeof(limits), 1, 4096};
    REQUIRE(aether_unzip_resource_mount_nested(subtree, "group/mixed/visible.zip", scratch,
                                               NULL, &limits, &nested) == AU_OK);
    aether_unzip_resource_unmount(subtree);
    REQUIRE(aether_unzip_resource_build_index(nested, 256) == AU_OK);
    REQUIRE(aether_unzip_resource_lookup(nested, "deep.zip", &entry) == AU_OK);
    aether_unzip_resource_unmount(nested);
    no_output(scratch);
}

static void nested_resources(void) {
    const char *scratch = directory("nested-scratch");
    int cancel = 0;
    au_options options = aether_unzip_options_default();
    options.cancel = cancelled;
    options.user = &cancel;
    au_source *source = fixture("nested.zip");
    au_resource_mount *outer = NULL, *middle = NULL, *inner = NULL;
    au_nested_limits limits = {sizeof(limits), 2, 4096};
    REQUIRE(aether_unzip_resource_mount(context, source, NULL, &options, &outer) == AU_OK);
    aether_unzip_source_close(source);
    REQUIRE(aether_unzip_resource_build_index(outer, 256) == AU_OK);
    const au_entry *package;
    REQUIRE(aether_unzip_resource_lookup(outer, "packages/内层.bin", &package) == AU_OK);
    REQUIRE(package->size_known && package->size > 1);

    au_nested_limits small = {sizeof(small), 2, package->size - 1};
    REQUIRE(aether_unzip_resource_mount_nested(outer, package->name, scratch, NULL, &small, &middle) == AU_LIMIT);
    REQUIRE(aether_unzip_resource_mount_nested(outer, "plain.txt", scratch, NULL, &limits, &middle) == AU_UNKNOWN_FORMAT);
    cancel = 1;
    REQUIRE(aether_unzip_resource_mount_nested(outer, package->name, scratch, NULL, &limits, &middle) == AU_CANCELLED);
    cancel = 0;
    no_output(scratch);

    au_nested_limits one = {sizeof(one), 1, 4096};
    REQUIRE(aether_unzip_resource_mount_nested(outer, package->name, scratch, NULL, &one, &middle) == AU_OK);
    REQUIRE(aether_unzip_resource_info(middle)->format == AU_FORMAT_ZIP);
    REQUIRE(aether_unzip_resource_build_index(middle, 256) == AU_OK);
    REQUIRE(aether_unzip_resource_mount_nested(middle, "deep.zip", scratch, NULL, &limits, &inner) == AU_LIMIT);
    aether_unzip_resource_unmount(middle);

    small.max_staged_bytes = package->size + 1;
    REQUIRE(aether_unzip_resource_mount_nested(outer, package->name, scratch, NULL, &small, &middle) == AU_OK);
    REQUIRE(aether_unzip_resource_build_index(middle, 256) == AU_OK);
    REQUIRE(aether_unzip_resource_mount_nested(middle, "deep.zip", scratch, NULL, &limits, &inner) == AU_LIMIT);
    aether_unzip_resource_unmount(middle);

    REQUIRE(aether_unzip_resource_mount_nested(outer, package->name, scratch, NULL, &limits, &middle) == AU_OK);
    aether_unzip_resource_unmount(outer);
    REQUIRE(aether_unzip_resource_build_index(middle, 256) == AU_OK);
    REQUIRE(aether_unzip_resource_mount_nested(middle, "deep.zip", scratch, NULL, &limits, &inner) == AU_OK);
    aether_unzip_resource_unmount(middle);
    no_output(scratch);
    REQUIRE(aether_unzip_resource_build_index(inner, 256) == AU_OK);
    au_resource_file *file = NULL;
    REQUIRE(aether_unzip_resource_open_path(inner, "docs/readme.txt", &file) == AU_OK);
    aether_unzip_resource_unmount(inner);
    char bytes[32];
    size_t count;
    REQUIRE(aether_unzip_resource_read(file, bytes, sizeof(bytes), &count) == AU_OK);
    REQUIRE(count == 16 && !memcmp(bytes, "Nested document\n", count));
    aether_unzip_resource_close(file);
    no_output(scratch);

    source = fixture("notes.gz");
    REQUIRE(aether_unzip_resource_mount(context, source, "notes.gz", NULL, &outer) == AU_OK);
    aether_unzip_source_close(source);
    REQUIRE(aether_unzip_resource_build_index(outer, 256) == AU_OK);
    REQUIRE(aether_unzip_resource_lookup(outer, "notes", &package) == AU_OK && !package->size_known);
    small.max_staged_bytes = 1;
    REQUIRE(aether_unzip_resource_mount_nested(outer, "notes", scratch, NULL, &small, &middle) == AU_LIMIT);
    aether_unzip_resource_unmount(outer);
    no_output(scratch);
}

static void resource_tests(void) {
    nested_resources();
    composed_resources();
    int cancel = 0;
    au_options options = aether_unzip_options_default();
    options.cancel = cancelled;
    options.user = &cancel;
    au_source *source = fixture("resource-index.zip");
    au_resource_mount *mount = NULL;
    REQUIRE(aether_unzip_resource_mount(context, source, NULL, &options, &mount) == AU_OK);
    aether_unzip_source_close(source);

    const au_entry *entry = NULL, *directory_entry = NULL;
    REQUIRE(aether_unzip_resource_lookup(mount, "docs", &entry) == AU_UNSUPPORTED);
    REQUIRE(aether_unzip_resource_next(mount, &entry) == AU_OK && entry->index == 0);
    REQUIRE(aether_unzip_resource_build_index(mount, 10) == AU_LIMIT);
    REQUIRE(aether_unzip_resource_lookup(mount, "docs", &entry) == AU_UNSUPPORTED);
    cancel = 1;
    REQUIRE(aether_unzip_resource_build_index(mount, 256) == AU_CANCELLED);
    cancel = 0;
    REQUIRE(aether_unzip_resource_build_index(mount, 256) == AU_OK);
    REQUIRE(aether_unzip_resource_lookup(mount, "./docs/", &directory_entry) == AU_OK);
    REQUIRE(directory_entry->kind == AU_ENTRY_DIRECTORY && directory_entry->name_length == 4);
    REQUIRE(!strcmp(directory_entry->name, "docs"));
    REQUIRE(aether_unzip_resource_build_index(mount, 0) == AU_OK);
    REQUIRE(aether_unzip_resource_lookup(mount, "docs", &entry) == AU_OK && entry == directory_entry);
    REQUIRE(aether_unzip_resource_lookup(mount, "docs/report.txt", &entry) == AU_EXISTS && !entry);
    REQUIRE(aether_unzip_resource_lookup(mount, "../excluded.txt", &entry) == AU_UNSAFE_PATH);
    REQUIRE(aether_unzip_resource_lookup(mount, "excluded.txt", &entry) == AU_NOT_FOUND);
    REQUIRE(aether_unzip_resource_lookup(mount, "docs/regional/样本.txt/", &entry) == AU_NOT_FOUND);
    REQUIRE(aether_unzip_resource_lookup(mount, "docs/regional/样本.txt", &entry) == AU_OK);
    REQUIRE(entry->index == 3 && entry->size_known && entry->size == 14);
    REQUIRE(aether_unzip_resource_next(mount, &entry) == AU_OK && entry->index == 1);

    au_resource_file *file = NULL;
    REQUIRE(aether_unzip_resource_open_path(mount, "docs", &file) == AU_UNSUPPORTED && !file);
    REQUIRE(aether_unzip_resource_open_path(mount, "docs/report.txt", &file) == AU_EXISTS && !file);
    REQUIRE(aether_unzip_resource_open_path(mount, "./docs/regional/样本.txt", &file) == AU_OK);
    REQUIRE(aether_unzip_resource_lookup(mount, "file/child.txt", &entry) == AU_EXISTS && !entry);
    au_resource_directory *root = NULL, *docs = NULL, *regional = NULL, *empty = NULL, *missing = NULL;
    REQUIRE(aether_unzip_resource_directory_open(mount, "file", &root) == AU_EXISTS && !root);
    REQUIRE(aether_unzip_resource_directory_open(mount, "", &root) == AU_OK);
    REQUIRE(aether_unzip_resource_directory_open(mount, "docs/", &docs) == AU_OK);
    REQUIRE(aether_unzip_resource_directory_open(mount, "docs/regional", &regional) == AU_OK);
    REQUIRE(aether_unzip_resource_directory_open(mount, "empty", &empty) == AU_OK);
    REQUIRE(aether_unzip_resource_directory_open(mount, "docs/missing", &missing) == AU_NOT_FOUND);
    aether_unzip_resource_unmount(mount);
    REQUIRE(aether_unzip_resource_directory_next(root, &entry) == AU_OK && entry == directory_entry);
    REQUIRE(aether_unzip_resource_directory_next(root, &entry) == AU_OK && !strcmp(entry->name, "empty"));
    REQUIRE(aether_unzip_resource_directory_next(root, &entry) == AU_EXISTS && !entry);
    REQUIRE(aether_unzip_resource_directory_next(root, &entry) == AU_OK && !strcmp(entry->name, "file-sibling.txt"));
    REQUIRE(aether_unzip_resource_directory_next(root, &entry) == AU_END);
    REQUIRE(aether_unzip_resource_directory_next(docs, &entry) == AU_OK);
    REQUIRE(entry->kind == AU_ENTRY_DIRECTORY && entry->index == UINT64_MAX);
    REQUIRE(!strcmp(entry->name, "docs/regional"));
    REQUIRE(aether_unzip_resource_directory_next(docs, &entry) == AU_EXISTS);
    REQUIRE(aether_unzip_resource_directory_next(docs, &entry) == AU_END);
    cancel = 1;
    REQUIRE(aether_unzip_resource_directory_next(regional, &entry) == AU_CANCELLED);
    cancel = 0;
    REQUIRE(aether_unzip_resource_directory_next(regional, &entry) == AU_OK && entry->index == 3);
    REQUIRE(aether_unzip_resource_directory_next(regional, &entry) == AU_END);
    REQUIRE(aether_unzip_resource_directory_next(empty, &entry) == AU_END);
    aether_unzip_resource_directory_close(root);
    aether_unzip_resource_directory_close(docs);
    aether_unzip_resource_directory_close(regional);
    aether_unzip_resource_directory_close(empty);
    char bytes[32];
    size_t count;
    REQUIRE(aether_unzip_resource_read(file, bytes, sizeof(bytes), &count) == AU_OK);
    REQUIRE(count == 14 && !memcmp(bytes, "Regional text\n", count));
    REQUIRE(aether_unzip_resource_read(file, bytes, sizeof(bytes), &count) == AU_OK && !count);
    aether_unzip_resource_close(file);

    const char *omitted[] = {"empty.zip", "symlink.zip"};
    for (size_t i = 0; i < sizeof(omitted) / sizeof(*omitted); ++i) {
        source = fixture(omitted[i]);
        REQUIRE(aether_unzip_resource_mount(context, source, NULL, NULL, &mount) == AU_OK);
        aether_unzip_source_close(source);
        REQUIRE(aether_unzip_resource_build_index(mount, 0) == AU_OK);
        REQUIRE(aether_unzip_resource_lookup(mount, "link", &entry) == AU_NOT_FOUND);
        aether_unzip_resource_unmount(mount);
    }

    options.max_path_depth = 3;
    source = fixture("deep.zip");
    REQUIRE(aether_unzip_resource_mount(context, source, NULL, &options, &mount) == AU_OK);
    aether_unzip_source_close(source);
    REQUIRE(aether_unzip_resource_build_index(mount, 256) == AU_LIMIT);
    aether_unzip_resource_unmount(mount);
}
static void cancel_during_write(void *flag, const au_entry *entry, uint64_t bytes,
                                uint64_t entry_bytes, uint64_t done) {
    (void)entry; (void)bytes; (void)done;
    if (entry_bytes) *(int *)flag = 1;
}

static void sevenzip_password_tests(au_context *correct, au_context *incorrect) {
    const char *fixtures[] = {
        "7z-aes-stored.7z", "7z-aes-solid.7z", "7z-aes-header.7z", "7z-aes-picker.7z"
    };
    au_context *unicode = NULL;
    REQUIRE(aether_unzip_context_create_with_passphrase("档案🔑", &unicode) == AU_OK);
    for (size_t i = 0; i < sizeof(fixtures) / sizeof(fixtures[0]); ++i) {
        int encrypted_header = i >= 2;
        au_context *password = i == 2 ? unicode : correct;
        au_source *source = fixture(fixtures[i]);
        au_archive *archive = NULL;
        const au_entry *entry = NULL;
        if (encrypted_header) {
            REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_ENCRYPTED);
            REQUIRE(!archive);
            REQUIRE(aether_unzip_archive_open(incorrect, source, NULL, NULL, &archive) ==
                    AU_BAD_PASSPHRASE);
            REQUIRE(!archive);
        }
        REQUIRE(aether_unzip_archive_open(encrypted_header ? password : context, source, NULL, NULL,
                                          &archive) == AU_OK);
        const au_probe_result *info = aether_unzip_archive_info(archive);
        REQUIRE(info->format == AU_FORMAT_7ZIP && (info->capabilities & AU_SUPPORTS_ENCRYPTION));
        REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
        REQUIRE(entry->encrypted && !strcmp(entry->name, "private.txt"));
        REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
        REQUIRE(entry->encrypted && !strcmp(entry->name, "second.txt"));
        uint64_t index = entry->index;
        REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_END);
        aether_unzip_archive_close(archive);

        const char *output = directory(fixtures[i]);
        REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_ENCRYPTED);
        REQUIRE(aether_unzip_extract(incorrect, source, NULL, output, NULL, 0, NULL) ==
                AU_BAD_PASSPHRASE);
        no_output(output);

        int stop = 0;
        au_options options = aether_unzip_options_default();
        options.cancel = cancelled;
        options.progress = cancel_during_write;
        options.user = &stop;
        REQUIRE(aether_unzip_extract(password, source, NULL, output, NULL, 0, &options) ==
                AU_CANCELLED);
        no_output(output);

        if (i == 1) {
            options = aether_unzip_options_default();
            options.max_total_bytes = 30;
            REQUIRE(aether_unzip_extract(password, source, NULL, output, &index, 1, &options) == AU_LIMIT);
            no_output(output);
        }
        REQUIRE(aether_unzip_extract(password, source, NULL, output, &index, 1, NULL) == AU_OK);
        char path[512];
        snprintf(path, sizeof(path), "%s/second.txt", output);
        contents(path, "Another protected document\n");
        snprintf(path, sizeof(path), "%s/private.txt", output);
        REQUIRE(access(path, F_OK) != 0);
        aether_unzip_source_close(source);
    }
    aether_unzip_context_destroy(unicode);
}

static int32_t cancel_rar5_derivation(void *user) {
    unsigned *polls = user;
    return ++*polls >= 4;
}

static void rar5_password_tests(au_context *correct, au_context *incorrect) {
    const char *names[] = {"rar5-aes-stored.rar", "rar5-aes-packed.rar", "rar5-aes-header.rar"};
    au_context *unicode = NULL;
    REQUIRE(aether_unzip_context_create_with_passphrase("档案🔑", &unicode) == AU_OK);
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        au_context *password = i == 2 ? unicode : correct;
        au_source *source = fixture(names[i]);
        au_archive *archive = NULL;
        const au_entry *entry = NULL;
        const char *output = directory(names[i]);
        if (i == 2) {
            unsigned polls = 0;
            au_options options = aether_unzip_options_default();
            options.user = &polls;
            options.cancel = cancel_rar5_derivation;
            REQUIRE(aether_unzip_archive_open(password, source, NULL, &options, &archive) == AU_CANCELLED);
            REQUIRE(!archive && polls >= 4);
            REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_ENCRYPTED);
            REQUIRE(aether_unzip_archive_open(incorrect, source, NULL, NULL, &archive) ==
                    AU_BAD_PASSPHRASE);
        }
        REQUIRE(aether_unzip_archive_open(i == 2 ? password : context,
                                          source, NULL, NULL, &archive) == AU_OK);
        const au_probe_result *info = aether_unzip_archive_info(archive);
        REQUIRE(info->format == AU_FORMAT_RAR5 && (info->capabilities & AU_SUPPORTS_ENCRYPTION));
        REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
        REQUIRE(entry->encrypted && !strcmp(entry->name, "private.txt"));
        if (i) {
            REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
            REQUIRE(entry->encrypted && !strcmp(entry->name, "second.txt"));
        }
        uint64_t last = entry->index;
        REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_END);
        aether_unzip_archive_close(archive);

        REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_ENCRYPTED);
        REQUIRE(aether_unzip_extract(incorrect, source, NULL, output, NULL, 0, NULL) ==
                AU_BAD_PASSPHRASE);
        no_output(output);

        REQUIRE(aether_unzip_extract(password, source, NULL, output, &last, 1, NULL) == AU_OK);
        char path[512];
        snprintf(path, sizeof(path), "%s/private.txt", output);
        if (i) {
            REQUIRE(access(path, F_OK) != 0);
            snprintf(path, sizeof(path), "%s/second.txt", output);
            content_hash(path, 232500, UINT64_C(0xd790cd71a7d5e019));
        } else {
            contents(path, "RAR5 protected document\n");
        }
        aether_unzip_source_close(source);
    }
    aether_unzip_context_destroy(unicode);

    au_source *damaged = fixture("rar5-aes-damaged.rar");
    const char *output = directory("rar5-aes-damaged");
    REQUIRE(aether_unzip_extract(correct, damaged, NULL, output, NULL, 0, NULL) == AU_CORRUPT);
    no_output(output);
    aether_unzip_source_close(damaged);
}

static void rar5_solid_password_tests(au_context *correct, au_context *incorrect) {
    const char *names[] = {"rar5-aes-solid.rar", "rar5-aes-solid-header.rar"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        au_source *source = fixture(names[i]);
        au_options options = aether_unzip_options_default();
        options.max_entry_bytes = options.max_total_bytes = 1;
        au_archive *catalog = NULL;
        const au_entry *entry = NULL;
        REQUIRE(aether_unzip_archive_open_catalog(i ? correct : context, source, NULL,
                                                  &options, &catalog) == AU_OK);
        REQUIRE(aether_unzip_archive_next_entry(catalog, &entry) == AU_OK);
        REQUIRE(entry->encrypted && !strcmp(entry->name, "private.txt"));
        size_t count;
        char byte;
        REQUIRE(aether_unzip_archive_read(catalog, &byte, 1, &count) == AU_UNSUPPORTED);
        REQUIRE(count == 0);
        REQUIRE(aether_unzip_archive_next_entry(catalog, &entry) == AU_OK);
        REQUIRE(entry->encrypted && !strcmp(entry->name, "second.txt"));
        REQUIRE(aether_unzip_archive_next_entry(catalog, &entry) == AU_OK);
        REQUIRE(entry->encrypted && !strcmp(entry->name, "third.txt"));
        uint64_t index = entry->index;
        REQUIRE(aether_unzip_archive_next_entry(catalog, &entry) == AU_END);
        aether_unzip_archive_close(catalog);

        const char *output = directory(names[i]);
        options = aether_unzip_options_default();
        options.max_total_bytes = 300000;
        REQUIRE(aether_unzip_extract(correct, source, NULL, output, &index, 1, &options) == AU_LIMIT);
        REQUIRE(aether_unzip_extract(context, source, NULL, output, &index, 1, NULL) == AU_ENCRYPTED);
        REQUIRE(aether_unzip_extract(incorrect, source, NULL, output, &index, 1, NULL) == AU_BAD_PASSPHRASE);
        no_output(output);
        REQUIRE(aether_unzip_extract(correct, source, NULL, output, &index, 1, NULL) == AU_OK);
        char path[512];
        snprintf(path, sizeof(path), "%s/private.txt", output);
        REQUIRE(access(path, F_OK) != 0);
        snprintf(path, sizeof(path), "%s/second.txt", output);
        REQUIRE(access(path, F_OK) != 0);
        snprintf(path, sizeof(path), "%s/third.txt", output);
        content_hash(path, 120409, UINT64_C(0x7dbf8c79fdc9cca8));

        au_resource_mount *mount = NULL;
        REQUIRE(aether_unzip_resource_mount(correct, source, NULL, NULL, &mount) == AU_OK);
        REQUIRE(aether_unzip_resource_build_index(mount, 256) == AU_OK);
        REQUIRE(aether_unzip_resource_lookup(mount, "third.txt", &entry) == AU_OK);
        REQUIRE(entry->index == index && entry->encrypted);
        au_resource_file *file = NULL;
        REQUIRE(aether_unzip_resource_open_path(mount, "third.txt", &file) == AU_OK);
        unsigned char data[65536];
        REQUIRE(aether_unzip_resource_read(file, data, sizeof(data), &count) == AU_OK);
        REQUIRE(count == sizeof(data));
        aether_unzip_resource_close(file);
        aether_unzip_resource_unmount(mount);
        aether_unzip_source_close(source);
    }
}

static void chinese_zip_password_tests(void) {
    const struct { const char *fixture, *password; } cases[] = {
        {"chinese-utf8-aes256.zip", " 资源密碼！Ａ1𠮷🔑 "},
        {"chinese-gbk-zipcrypto.zip", " 资源密碼！Ａ1 "},
        {"chinese-gbk-aes256.zip", " 资源密碼！Ａ1 "},
        {"chinese-big5-zipcrypto.zip", " 資源密碼！Ａ1 "},
        {"chinese-big5-aes256.zip", " 資源密碼！Ａ1 "},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        au_context *password = NULL;
        REQUIRE(aether_unzip_context_create_with_passphrase(cases[i].password, &password) == AU_OK);
        au_source *source = fixture(cases[i].fixture);
        au_probe_result info = {.struct_size = sizeof(info)};
        REQUIRE(aether_unzip_probe(context, source, NULL, &info) == AU_OK && info.format == AU_FORMAT_ZIP);
        const char *output = directory(cases[i].fixture);
        REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_ENCRYPTED);
        no_output(output);
        REQUIRE(aether_unzip_extract(password, source, NULL, output, NULL, 0, NULL) == AU_OK);
        char path[512];
        snprintf(path, sizeof(path), "%s/private.txt", output);
        contents(path, "Chinese password fixture\n");
        aether_unzip_source_close(source);
        aether_unzip_context_destroy(password);
    }
}

static void password_tests(void) {
    const char *fixtures[] = {"zipcrypto.zip", "aes256.zip"};
    au_context *correct = NULL, *incorrect = NULL;
    REQUIRE(aether_unzip_context_create_with_passphrase("", &correct) == AU_INVALID);
    REQUIRE(!correct);
    REQUIRE(aether_unzip_context_create_with_passphrase("fixture-pass", &correct) == AU_OK);
    REQUIRE(aether_unzip_context_create_with_passphrase("wrong-password", &incorrect) == AU_OK);
    for (size_t i = 0; i < sizeof(fixtures) / sizeof(fixtures[0]); ++i) {
        au_source *source = fixture(fixtures[i]);
        au_probe_result info = {.struct_size = sizeof(info)};
        REQUIRE(aether_unzip_probe(context, source, NULL, &info) == AU_OK);
        REQUIRE(info.format == AU_FORMAT_ZIP && (info.capabilities & AU_SUPPORTS_ENCRYPTION));
        au_archive *archive = NULL;
        const au_entry *entry;
        uint64_t index = UINT64_MAX;
        REQUIRE(aether_unzip_archive_open(context, source, NULL, NULL, &archive) == AU_OK);
        while (aether_unzip_archive_next_entry(archive, &entry) == AU_OK) {
            if (entry->encrypted) {
                REQUIRE(!strcmp(entry->name, "private.txt"));
                index = entry->index;
            }
        }
        REQUIRE(index != UINT64_MAX);
        aether_unzip_archive_close(archive);

        const char *output = directory(fixtures[i]);
        REQUIRE(aether_unzip_extract(context, source, NULL, output, &index, 1, NULL) == AU_ENCRYPTED);
        REQUIRE(aether_unzip_extract(incorrect, source, NULL, output, &index, 1, NULL) ==
                AU_BAD_PASSPHRASE);
        no_output(output);
        REQUIRE(aether_unzip_extract(correct, source, NULL, output, &index, 1, NULL) == AU_OK);
        char path[512];
        snprintf(path, sizeof(path), "%s/private.txt", output);
        contents(path, "Protected document\n");
        snprintf(path, sizeof(path), "%s/public.txt", output);
        REQUIRE(access(path, F_OK) != 0);

        au_context *temporary = NULL;
        au_resource_mount *mount = NULL;
        au_resource_file *file = NULL;
        REQUIRE(aether_unzip_resource_mount(context, source, NULL, NULL, &mount) == AU_OK);
        REQUIRE(aether_unzip_resource_build_index(mount, 256) == AU_OK);
        REQUIRE(aether_unzip_resource_lookup(mount, "private.txt", &entry) == AU_OK);
        REQUIRE(entry->encrypted && entry->index == index);
        REQUIRE(aether_unzip_resource_open_path(mount, "private.txt", &file) == AU_ENCRYPTED);
        aether_unzip_resource_unmount(mount);
        REQUIRE(aether_unzip_context_create_with_passphrase("fixture-pass", &temporary) == AU_OK);
        REQUIRE(aether_unzip_resource_mount(temporary, source, NULL, NULL, &mount) == AU_OK);
        aether_unzip_context_destroy(temporary);
        REQUIRE(aether_unzip_resource_build_index(mount, 256) == AU_OK);
        REQUIRE(aether_unzip_resource_open_path(mount, "private.txt", &file) == AU_OK);
        aether_unzip_resource_unmount(mount);
        char buffer[64];
        size_t n;
        REQUIRE(aether_unzip_resource_read(file, buffer, sizeof(buffer), &n) == AU_OK);
        REQUIRE(n == strlen("Protected document\n"));
        REQUIRE(!memcmp(buffer, "Protected document\n", n));
        aether_unzip_resource_close(file);
        aether_unzip_source_close(source);
    }
    sevenzip_password_tests(correct, incorrect);
    rar5_password_tests(correct, incorrect);
    rar5_solid_password_tests(correct, incorrect);
    chinese_zip_password_tests();
    aether_unzip_context_destroy(incorrect);
    aether_unzip_context_destroy(correct);
}

static void security_tests(void) {
    const char *output = directory("unsafe");
    const char *bad[] = {"traversal.zip", "absolute.zip", "windows-path.zip", "symlink.zip"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); ++i) {
        au_source *source = fixture(bad[i]);
        REQUIRE(aether_unzip_extract(context, source, bad[i], output, NULL, 0, NULL) ==
                (i == 3 ? AU_UNSUPPORTED : AU_UNSAFE_PATH));
        no_output(output);
        aether_unzip_source_close(source);
    }
    char path[512];
    snprintf(path, sizeof(path), "%s/escaped.txt", work);
    REQUIRE(access(path, F_OK) != 0);

    au_options catalog_options = aether_unzip_options_default();
    catalog_options.max_entry_bytes = 1;
    catalog_options.max_total_bytes = 1;
    au_source *tar = fixture("sample.tar");
    au_archive *tar_catalog = NULL;
    REQUIRE(aether_unzip_archive_open_catalog(context, tar, NULL, &catalog_options, &tar_catalog) == AU_OK);
    const au_entry *tar_entry;
    au_status catalog_status;
    size_t tar_files = 0;
    while ((catalog_status = aether_unzip_archive_next_entry(tar_catalog, &tar_entry)) == AU_OK) {
        if (tar_entry->kind == AU_ENTRY_FILE) ++tar_files;
    }
    REQUIRE(catalog_status == AU_END && tar_files == 1);
    aether_unzip_archive_close(tar_catalog);
    REQUIRE(aether_unzip_extract(context, tar, NULL, output, NULL, 0, &catalog_options) == AU_LIMIT);
    no_output(output);
    aether_unzip_source_close(tar);

    tar = fixture("sample.tar.gz");
    REQUIRE(aether_unzip_archive_open_catalog(context, tar, NULL, &catalog_options, &tar_catalog) == AU_OK);
    while ((catalog_status = aether_unzip_archive_next_entry(tar_catalog, &tar_entry)) == AU_OK) {}
    REQUIRE(catalog_status == AU_LIMIT);
    aether_unzip_archive_close(tar_catalog);
    aether_unzip_source_close(tar);

    const char *bad_gzip[] = {"gzip-crc.gz", "gzip-size.gz"};
    for (size_t i = 0; i < sizeof(bad_gzip) / sizeof(bad_gzip[0]); ++i) {
        au_source *gzip = fixture(bad_gzip[i]);
        REQUIRE(aether_unzip_extract(context, gzip, bad_gzip[i], output, NULL, 0, NULL)
                == AU_CORRUPT);
        no_output(output);
        aether_unzip_source_close(gzip);
    }

    au_source *brotli = fixture("notes.br");
    unsigned char data[64];
    size_t n;
    REQUIRE(aether_unzip_source_read_at(brotli, 0, data, sizeof(data) - 1, &n) == AU_OK);
    aether_unzip_source_close(brotli);
    data[n] = 0;
    REQUIRE(aether_unzip_source_memory(data, n + 1, &brotli) == AU_OK);
    REQUIRE(aether_unzip_extract(context, brotli, "trailing.br", output, NULL, 0, NULL)
            == AU_CORRUPT);
    no_output(output);
    aether_unzip_source_close(brotli);
    brotli = fixture("expansion.br");
    REQUIRE(aether_unzip_extract(context, brotli, "expansion.br", output, NULL, 0, NULL)
            == AU_LIMIT);
    no_output(output);
    aether_unzip_source_close(brotli);

    au_source *source = fixture("deep.zip");
    au_options options = aether_unzip_options_default();
    options.max_path_depth = 3;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_LIMIT);
    no_output(output);
    aether_unzip_source_close(source);

    source = fixture("expansion.zip");
    options = aether_unzip_options_default();
    options.max_entry_bytes = 1000;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_LIMIT);
    options = aether_unzip_options_default();
    options.max_expansion_ratio = 20;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_LIMIT);
    no_output(output);
    int flag = 0;
    options = aether_unzip_options_default();
    options.cancel = cancelled;
    options.progress = cancel_during_write;
    options.user = &flag;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_CANCELLED);
    REQUIRE(flag);
    no_output(output);
    aether_unzip_source_close(source);

    source = fixture("sample.zip");
    options = aether_unzip_options_default();
    options.max_total_bytes = 1;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_LIMIT);
    no_output(output);
    const uint64_t selected = 1, missing = 12;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, &missing, 1, NULL) == AU_NOT_FOUND);
    snprintf(path, sizeof(path), "%s/docs", output);
    REQUIRE(symlink(work, path) == 0);
    REQUIRE(aether_unzip_extract(context, source, NULL, output, &selected, 1, NULL) == AU_UNSAFE_PATH);
    REQUIRE(unlink(path) == 0);
    snprintf(path, sizeof(path), "%s/readme.txt", work);
    REQUIRE(access(path, F_OK) != 0);

    output = directory("safe");
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_OK);
    snprintf(path, sizeof(path), "%s/notes.txt", output);
    contents(path, message);
    snprintf(path, sizeof(path), "%s/docs/空白.txt", output);
    contents(path, "");
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, NULL) == AU_EXISTS);
    snprintf(path, sizeof(path), "%s/notes.txt", output);
    FILE *existing = fopen(path, "wb");
    REQUIRE(existing && fputs("existing", existing) >= 0 && fclose(existing) == 0);
    options = aether_unzip_options_default();
    options.conflict_policy = AU_CONFLICT_SKIP;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_OK);
    contents(path, "existing");
    options.conflict_policy = AU_CONFLICT_REPLACE;
    REQUIRE(aether_unzip_extract(context, source, NULL, output, NULL, 0, &options) == AU_OK);
    contents(path, message);

    options.max_entries = 1;
    au_archive *archive = NULL;
    const au_entry *entry;
    REQUIRE(aether_unzip_archive_open(context, source, NULL, &options, &archive) == AU_OK);
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_OK);
    REQUIRE(aether_unzip_archive_next_entry(archive, &entry) == AU_LIMIT);
    aether_unzip_archive_close(archive);
    aether_unzip_source_close(source);
}

static void cancel_after_first_file(void *user, const au_entry *entry, uint64_t bytes_written,
                                   uint64_t entry_bytes_written, uint64_t entries_done) {
    (void)entry;
    (void)bytes_written;
    if (entries_done && entry_bytes_written) *(int *)user = 1;
}

static void extraction_cancellation_test(void) {
    const char *output = directory("partial-cancellation");
    au_source *source = fixture("sample.zip");
    int cancel = 0;
    au_options options = aether_unzip_options_default();
    options.user = &cancel;
    options.cancel = cancelled;
    options.progress = cancel_after_first_file;
    REQUIRE(aether_unzip_extract(context, source, "sample.zip", output, NULL, 0, &options) == AU_CANCELLED);
    REQUIRE(cancel);
    char path[512];
    snprintf(path, sizeof(path), "%s/notes.txt", output);
    contents(path, message);
    snprintf(path, sizeof(path), "%s/docs", output);
    no_output(path);
    aether_unzip_source_close(source);
}

static void extraction_layout_tests(void) {
    const char *fixtures[] = {"layout.zip", "layout.tar.gz"};
    char path[512];
    au_options options = aether_unzip_options_default();
    for (size_t i = 0; i < sizeof(fixtures) / sizeof(fixtures[0]); ++i) {
        const char *output = directory(i == 0 ? "zip-layout" : "tar-layout");
        au_source *source = fixture(fixtures[i]);
        REQUIRE(aether_unzip_extract_stripping_root(context, source, fixtures[i], output,
            NULL, 0, "Lay", NULL) == AU_INVALID);
        REQUIRE(aether_unzip_extract_stripping_root(context, source, fixtures[i], output,
            NULL, 0, "../Layout", NULL) == AU_INVALID);
        options.max_path_depth = 2;
        REQUIRE(aether_unzip_extract_stripping_root(context, source, fixtures[i], output,
            NULL, 0, "Layout", &options) == AU_LIMIT);
        no_output(output);
        options = aether_unzip_options_default();
        REQUIRE(aether_unzip_extract_stripping_root(context, source, fixtures[i], output,
            NULL, 0, "Layout", &options) == AU_OK);
        snprintf(path, sizeof(path), "%s/notes.txt", output);
        contents(path, message);
        snprintf(path, sizeof(path), "%s/docs/readme.txt", output);
        contents(path, "Nested document\n");
        snprintf(path, sizeof(path), "%s/Layout", output);
        REQUIRE(access(path, F_OK) != 0);
        options.conflict_policy = AU_CONFLICT_KEEP_BOTH;
        REQUIRE(aether_unzip_extract_stripping_root(context, source, fixtures[i], output,
            NULL, 0, "Layout", &options) == AU_OK);
        snprintf(path, sizeof(path), "%s/notes (2).txt", output);
        contents(path, message);
        aether_unzip_source_close(source);
    }
    const char *output = directory("layout-unsafe");
    au_source *source = fixture("layout-unsafe.zip");
    REQUIRE(aether_unzip_extract_stripping_root(context, source, "layout-unsafe.zip", output,
        NULL, 0, "Layout", NULL) == AU_UNSAFE_PATH);
    no_output(output);
    aether_unzip_source_close(source);

    output = directory("input-conflict");
    source = fixture("sample.zip");
    unsigned char bytes[4096];
    size_t length;
    REQUIRE(aether_unzip_source_read_at(source, 0, bytes, sizeof(bytes), &length) == AU_OK);
    REQUIRE(length < sizeof(bytes));
    aether_unzip_source_close(source);
    snprintf(path, sizeof(path), "%s/notes.txt", output);
    FILE *input = fopen(path, "wb");
    REQUIRE(input && fwrite(bytes, 1, length, input) == length && fclose(input) == 0);
    REQUIRE(aether_unzip_source_file(path, &source) == AU_OK);
    options.conflict_policy = AU_CONFLICT_REPLACE;
    REQUIRE(aether_unzip_extract(context, source, "sample.zip", output, NULL, 0, &options) == AU_EXISTS);
    aether_unzip_source_close(source);
    unsigned char after[sizeof(bytes)];
    input = fopen(path, "rb");
    REQUIRE(input && fread(after, 1, sizeof(after), input) == length && fclose(input) == 0);
    REQUIRE(memcmp(bytes, after, length) == 0);
}

int main(int argc, char **argv) {
    REQUIRE(argc == 2 && mkdtemp(work));
    cwd = open(".", O_RDONLY);
    REQUIRE(cwd >= 0);
    REQUIRE(aether_unzip_context_create(&context) == AU_OK);
    if (!strcmp(argv[1], "io")) io_test();
    else if (!strcmp(argv[1], "formats")) format_tests();
    else if (!strcmp(argv[1], "password")) password_tests();
    else if (!strcmp(argv[1], "security")) {
        security_tests();
        extraction_layout_tests();
        extraction_cancellation_test();
    }
    else if (!strcmp(argv[1], "resource")) resource_tests();
    else if (!strcmp(argv[1], "profile")) profile_tests();
    else REQUIRE(0);
    aether_unzip_context_destroy(context);
    remove_tree(cwd, work);
    close(cwd);
    return 0;
}
