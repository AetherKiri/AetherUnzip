#include "internal.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

typedef struct {
    au_encoder encoder;
    au_options options;
    uint64_t entries, bytes;
    char path[4097];
    unsigned char buffer[65536];
} archive_writer;

static int has_suffix(const char *name, const char *suffix) {
    size_t length = strlen(name), suffix_length = strlen(suffix);
    return length > suffix_length && !strcasecmp(name + length - suffix_length, suffix);
}

static int component_valid(const char *name) {
    const char *normalized = NULL;
    size_t length;
    return name && au_valid_utf8(name) &&
           au_normalize_path(name, AU_ENTRY_FILE, 1, &normalized, &length) == AU_OK && normalized == name;
}

static au_status input_error(int error) {
    if (error == ELOOP || error == ENOTDIR) return AU_UNSAFE_PATH;
    if (error == ENOENT) return AU_NOT_FOUND;
    return AU_IO;
}

static au_status write_file(archive_writer *writer, int fd, const struct stat *initial) {
    uint64_t remaining = (uint64_t)initial->st_size;
    while (remaining) {
        if (au_cancelled(&writer->options)) return AU_CANCELLED;
        size_t size = remaining < sizeof(writer->buffer) ? (size_t)remaining : sizeof(writer->buffer);
        ssize_t count = read(fd, writer->buffer, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return AU_IO;
        au_status status = writer->encoder.write(writer->encoder.state, writer->buffer, (size_t)count);
        if (status != AU_OK) return status;
        remaining -= (uint64_t)count;
    }
    struct stat current;
    if (fstat(fd, &current) || current.st_size != initial->st_size || current.st_mtime != initial->st_mtime)
        return AU_IO;
#ifdef __APPLE__
    if (current.st_mtimespec.tv_nsec != initial->st_mtimespec.tv_nsec) return AU_IO;
#else
    if (current.st_mtim.tv_nsec != initial->st_mtim.tv_nsec) return AU_IO;
#endif
    writer->bytes += (uint64_t)initial->st_size;
    return AU_OK;
}

static au_status write_item(archive_writer *, int, const char *, size_t, uint32_t);

static au_status write_children(archive_writer *writer, int fd, size_t length, uint32_t depth) {
    int descriptor = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (descriptor < 0) return AU_IO;
    DIR *directory = fdopendir(descriptor);
    if (!directory) { close(descriptor); return AU_IO; }
    au_status status = AU_OK;
    while (status == AU_OK) {
        if (au_cancelled(&writer->options)) { status = AU_CANCELLED; break; }
        errno = 0;
        struct dirent *child = readdir(directory);
        if (!child) { if (errno) status = AU_IO; break; }
        if (!strcmp(child->d_name, ".") || !strcmp(child->d_name, "..")) continue;
        status = write_item(writer, fd, child->d_name, length, depth + 1);
    }
    closedir(directory);
    return status;
}

static au_status write_item(archive_writer *writer, int parent, const char *name,
                            size_t prefix, uint32_t depth) {
    if (au_cancelled(&writer->options)) return AU_CANCELLED;
    if (depth > writer->options.max_path_depth || depth > 64 ||
        writer->entries >= writer->options.max_entries) return AU_LIMIT;
    if (!component_valid(name)) return AU_UNSAFE_PATH;
    if (prefix) writer->path[prefix++] = '/';
    size_t size = strlen(name);
    if (size >= sizeof(writer->path) - prefix) return AU_LIMIT;
    memcpy(writer->path + prefix, name, size + 1);

    struct stat expected, info;
    if (fstatat(parent, name, &expected, AT_SYMLINK_NOFOLLOW)) return input_error(errno);
    int is_directory = S_ISDIR(expected.st_mode);
    if (!is_directory && !S_ISREG(expected.st_mode)) return AU_UNSUPPORTED;
    int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    int fd = openat(parent, name, is_directory ? flags | O_DIRECTORY : flags);
    if (fd < 0) return input_error(errno);
    au_status status = AU_OK;
    if (fstat(fd, &info) || info.st_dev != expected.st_dev || info.st_ino != expected.st_ino ||
        (is_directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode))) {
        status = AU_IO;
    } else if (!is_directory && (info.st_size < 0 || (uint64_t)info.st_size > writer->options.max_entry_bytes ||
               (uint64_t)info.st_size > writer->options.max_total_bytes - writer->bytes)) {
        status = AU_LIMIT;
    } else {
        ++writer->entries;
        status = writer->encoder.begin(writer->encoder.state, writer->path, &info);
        if (status == AU_OK && !is_directory) status = write_file(writer, fd, &info);
        if (status == AU_OK) status = writer->encoder.end(writer->encoder.state);
        if (status == AU_OK && is_directory) status = write_children(writer, fd, prefix + size, depth);
    }
    close(fd);
    return status;
}

static int compare_names(const void *left, const void *right) {
    return strcmp(*(const char *const *)left, *(const char *const *)right);
}

static au_status write_archive(int root, int fd, const char *const *names, size_t count,
                               const char *temporary, au_write_format format, const au_options *options) {
    archive_writer writer = {.options = *options};
    au_status status = format == AU_WRITE_XP3
        ? au_xp3_encoder_open(fd, &writer.encoder)
        : au_libarchive_encoder_open(fd, format, &writer.encoder);
    if (status != AU_OK) return status;
    for (size_t i = 0; i < count && status == AU_OK; ++i) {
        status = !strcmp(names[i], temporary) ? AU_NOT_FOUND : write_item(&writer, root, names[i], 0, 1);
    }
    if (status == AU_OK) status = writer.encoder.finish(writer.encoder.state);
    writer.encoder.destroy(writer.encoder.state);
    return status;
}

au_status aether_unzip_create_archive(const char *directory, const char *const *names, size_t count,
                                     const char *archive_name, const au_options *options) {
    if (!directory || !names || !count || !component_valid(archive_name)) return AU_INVALID;
    au_write_format format;
    if (has_suffix(archive_name, ".zip")) format = AU_WRITE_ZIP;
    else if (has_suffix(archive_name, ".tar")) format = AU_WRITE_TAR;
    else if (has_suffix(archive_name, ".tar.gz")) format = AU_WRITE_TAR_GZIP;
    else if (has_suffix(archive_name, ".tar.zst")) format = AU_WRITE_TAR_ZSTD;
    else if (has_suffix(archive_name, ".xp3")) format = AU_WRITE_XP3;
    else return AU_INVALID;
    au_options resolved;
    au_status status = au_options_resolve(options, &resolved);
    if (status != AU_OK) return status;
    if (count > resolved.max_entries || count > SIZE_MAX / sizeof(*names)) return AU_LIMIT;
    if (au_cancelled(&resolved)) return AU_CANCELLED;
    for (size_t i = 0; i < count; ++i) if (!component_valid(names[i])) return AU_UNSAFE_PATH;

    const char **ordered = malloc(count * sizeof(*ordered));
    if (!ordered) return AU_NOMEM;
    memcpy(ordered, names, count * sizeof(*ordered));
    qsort(ordered, count, sizeof(*ordered), compare_names);
    for (size_t i = 1; i < count; ++i) {
        if (!strcmp(ordered[i - 1], ordered[i])) { free(ordered); return AU_INVALID; }
    }

    int root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) { free(ordered); return input_error(errno); }
    struct stat existing;
    if (!fstatat(root, archive_name, &existing, AT_SYMLINK_NOFOLLOW)) status = AU_EXISTS;
    else if (errno != ENOENT) status = au_output_error(errno);
    else {
        char temporary[96];
        int fd = au_open_temp(root, archive_name, temporary, sizeof(temporary), O_WRONLY);
        if (fd < 0) status = au_output_error(errno);
        else {
            status = write_archive(root, fd, ordered, count, temporary, format, &resolved);
            if (close(fd) && status == AU_OK) status = au_output_error(errno);
            if (status == AU_OK && au_cancelled(&resolved)) status = AU_CANCELLED;
            if (status == AU_OK) status = au_publish_exclusive(root, temporary, archive_name);
            if (temporary[0] && unlinkat(root, temporary, 0) && errno != ENOENT && status == AU_OK) status = AU_IO;
        }
    }
    close(root);
    free(ordered);
    return status;
}

au_status aether_unzip_create_zip(const char *directory, const char *const *names, size_t count,
                                 const char *archive_name, const au_options *options) {
    if (!archive_name || !has_suffix(archive_name, ".zip")) return AU_INVALID;
    return aether_unzip_create_archive(directory, names, count, archive_name, options);
}
