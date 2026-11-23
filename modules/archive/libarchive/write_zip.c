#include "internal.h"
#include <archive.h>
#include <archive_entry.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

typedef struct {
    struct archive *archive;
    struct archive_entry *entry;
    au_options options;
    uint64_t entries, bytes;
    char path[4097];
    unsigned char buffer[65536];
} zip_writer;

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

static au_status writer_error(zip_writer *writer) {
    int error = archive_errno(writer->archive);
    return error == ENOMEM ? AU_NOMEM : au_output_error(error);
}

static au_status write_file(zip_writer *writer, int fd, const struct stat *initial) {
    uint64_t remaining = (uint64_t)initial->st_size;
    while (remaining) {
        if (au_cancelled(&writer->options)) return AU_CANCELLED;
        size_t size = remaining < sizeof(writer->buffer) ? (size_t)remaining : sizeof(writer->buffer);
        ssize_t count = read(fd, writer->buffer, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return AU_IO;
        if (archive_write_data(writer->archive, writer->buffer, (size_t)count) != count)
            return writer_error(writer);
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

static au_status write_item(zip_writer *, int, const char *, size_t, uint32_t);

static au_status write_children(zip_writer *writer, int fd, size_t length, uint32_t depth) {
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

static au_status write_item(zip_writer *writer, int parent, const char *name,
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
        archive_entry_clear(writer->entry);
        archive_entry_set_pathname(writer->entry, writer->path);
        archive_entry_set_filetype(writer->entry, is_directory ? AE_IFDIR : AE_IFREG);
        archive_entry_set_perm(writer->entry, is_directory ? 0755 : 0644);
        archive_entry_set_mtime(writer->entry, info.st_mtime, 0);
        archive_entry_set_size(writer->entry, is_directory ? 0 : info.st_size);
        if (archive_write_header(writer->archive, writer->entry) != ARCHIVE_OK) status = writer_error(writer);
        if (status == AU_OK && !is_directory) status = write_file(writer, fd, &info);
        if (status == AU_OK && archive_write_finish_entry(writer->archive) != ARCHIVE_OK)
            status = writer_error(writer);
        if (status == AU_OK && is_directory) status = write_children(writer, fd, prefix + size, depth);
    }
    close(fd);
    return status;
}

static int compare_names(const void *left, const void *right) {
    return strcmp(*(const char *const *)left, *(const char *const *)right);
}

static au_status write_zip(int root, int fd, const char *const *names, size_t count,
                           const char *temporary, const au_options *options) {
    locale_t utf8 = newlocale(LC_CTYPE_MASK, "C.UTF-8", NULL);
    if (!utf8) utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    if (!utf8) return AU_UNSUPPORTED;
    locale_t original = uselocale(utf8);
    if (!original) { freelocale(utf8); return AU_IO; }

    zip_writer writer = {.archive = archive_write_new(), .entry = archive_entry_new(), .options = *options};
    au_status status = AU_OK;
    if (!writer.archive || !writer.entry) status = AU_NOMEM;
    else if (archive_write_set_format_zip(writer.archive) != ARCHIVE_OK ||
             archive_write_zip_set_compression_deflate(writer.archive) != ARCHIVE_OK ||
             archive_write_set_bytes_per_block(writer.archive, 0) != ARCHIVE_OK ||
             archive_write_open_fd(writer.archive, fd) != ARCHIVE_OK) status = writer_error(&writer);
    for (size_t i = 0; i < count && status == AU_OK; ++i) {
        status = !strcmp(names[i], temporary) ? AU_NOT_FOUND : write_item(&writer, root, names[i], 0, 1);
    }
    if (status == AU_OK && archive_write_close(writer.archive) != ARCHIVE_OK) status = writer_error(&writer);
    if (writer.archive) {
        if (status != AU_OK) archive_write_fail(writer.archive);
        archive_write_free(writer.archive);
    }
    archive_entry_free(writer.entry);
    uselocale(original);
    freelocale(utf8);
    return status;
}

au_status aether_unzip_create_zip(const char *directory, const char *const *names, size_t count,
                                 const char *archive_name, const au_options *options) {
    if (!directory || !names || !count || !component_valid(archive_name)) return AU_INVALID;
    size_t length = strlen(archive_name);
    if (length <= 4 || strcasecmp(archive_name + length - 4, ".zip")) return AU_INVALID;
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
            status = write_zip(root, fd, ordered, count, temporary, &resolved);
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
