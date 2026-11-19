#include "internal.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static au_status make_directory(int parent, const char *name) {
    if (mkdirat(parent, name, 0700) == 0) return AU_OK;
    if (errno != EEXIST) return AU_IO;
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW)) return AU_IO;
    return S_ISDIR(info.st_mode) ? AU_OK : AU_UNSAFE_PATH;
}

static au_status existing_file(int parent, const char *name, int *exists) {
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW)) {
        *exists = 0;
        return errno == ENOENT ? AU_OK : AU_IO;
    }
    *exists = 1;
    return S_ISREG(info.st_mode) ? AU_OK : AU_UNSAFE_PATH;
}

static au_status publish(int parent, const char *temporary, const char *name, uint32_t policy) {
    if (policy == AU_CONFLICT_REPLACE) {
        int exists;
        au_status status = existing_file(parent, name, &exists);
        if (status != AU_OK) return status;
        return renameat(parent, temporary, parent, name) ? AU_IO : AU_OK;
    }
#ifdef __APPLE__
    if (!renameatx_np(parent, temporary, parent, name, RENAME_EXCL)) return AU_OK;
    if (errno == ENOTSUP || errno == EINVAL)
#endif
    {
        if (!linkat(parent, temporary, parent, name, 0)) return AU_OK;
    }
    if (errno != EEXIST) return AU_IO;
    if (policy == AU_CONFLICT_FAIL) return AU_EXISTS;
    int exists;
    au_status status = existing_file(parent, name, &exists);
    return status == AU_OK ? AU_END : status;
}

static au_status write_file(au_archive *archive, int parent, const char *name,
                            uint64_t *written, uint64_t done) {
    const au_options *options = &archive->options;
    if (archive->entry.size_known &&
        (archive->entry.size > options->max_entry_bytes ||
         archive->entry.size > archive->max_total - archive->total_bytes)) return AU_LIMIT;
    int exists;
    au_status status = existing_file(parent, name, &exists);
    if (status != AU_OK) return status;
    if (exists && options->conflict_policy != AU_CONFLICT_REPLACE)
        return options->conflict_policy == AU_CONFLICT_SKIP ? AU_OK : AU_EXISTS;

    char temporary[96];
    int fd = au_open_temp(parent, name, temporary, sizeof(temporary), O_WRONLY);
    if (fd < 0) return AU_IO;
    unsigned char buffer[65536];
    uint64_t staged = 0;
    size_t n;
    while ((status = aether_unzip_archive_read(archive, buffer, sizeof(buffer), &n)) == AU_OK && n) {
        status = au_write_all(fd, buffer, n);
        if (status != AU_OK) break;
        staged += n;
        if (options->progress)
            options->progress(options->user, &archive->entry, *written + staged, staged, done);
    }
    if (close(fd) && status == AU_OK) status = AU_IO;
    if (status == AU_OK && au_cancelled(options)) status = AU_CANCELLED;
    if (status == AU_OK) status = publish(parent, temporary, name, options->conflict_policy);
    if (unlinkat(parent, temporary, 0) && errno != ENOENT && (status == AU_OK || status == AU_END)) status = AU_IO;
    if (status == AU_OK) *written += staged;
    return status == AU_END ? AU_OK : status;
}

au_status aether_unzip_extract(const au_context *context, au_source *source, const char *name_hint,
                               const char *directory, const uint64_t *selection,
                               size_t selection_count, const au_options *options) {
    if (!directory || (!selection && selection_count) || (selection && !selection_count))
        return AU_INVALID;
    for (size_t i = 1; i < selection_count; ++i)
        if (selection[i] <= selection[i - 1]) return AU_INVALID;

    au_archive *archive = NULL;
    au_status status = aether_unzip_archive_open(context, source, name_hint, options, &archive);
    if (status != AU_OK) return status;
    int root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) {
        int error = errno;
        aether_unzip_archive_close(archive);
        return error == ELOOP || error == ENOTDIR ? AU_UNSAFE_PATH : AU_IO;
    }

    uint64_t done = 0, written = 0;
    size_t selected = 0;
    const au_entry *entry;
    while ((status = aether_unzip_archive_next_entry(archive, &entry)) == AU_OK) {
        if (selection && entry->index != selection[selected]) continue;
        status = au_archive_entry_access(archive);
        if (status != AU_OK) break;
        if (entry->kind == AU_ENTRY_OTHER) { status = AU_UNSUPPORTED; break; }
        int parent;
        char *leaf;
        status = au_safe_parent(root, entry, archive->options.max_path_depth, &parent, &leaf);
        if (status == AU_OK) {
            status = entry->kind == AU_ENTRY_DIRECTORY ? make_directory(parent, leaf) :
                write_file(archive, parent, leaf, &written, done);
            free(leaf);
            close(parent);
        }
        if (status != AU_OK && status != AU_END) break;
        ++done;
        if (archive->options.progress)
            archive->options.progress(archive->options.user, entry, written, 0, done);
        if (au_cancelled(&archive->options)) { status = AU_CANCELLED; break; }
        if (selection && ++selected == selection_count) { status = AU_OK; break; }
    }
    if (status == AU_END) status = selection && selected < selection_count ? AU_NOT_FOUND : AU_OK;
    close(root);
    aether_unzip_archive_close(archive);
    return status;
}
