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
    if (errno != EEXIST) return au_output_error(errno);
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW)) return AU_IO;
    return S_ISDIR(info.st_mode) ? AU_OK : AU_UNSAFE_PATH;
}

static au_status existing_file(int parent, const char *name, int *exists, const au_source *protected_source) {
    struct stat info;
    if (fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW)) {
        *exists = 0;
        return errno == ENOENT ? AU_OK : AU_IO;
    }
    *exists = 1;
    if (!S_ISREG(info.st_mode)) return AU_UNSAFE_PATH;
    return protected_source && au_source_uses_file(protected_source, &info) ? AU_EXISTS : AU_OK;
}

static au_status publish_numbered(int parent, char *temporary, const char *name) {
    size_t length = strlen(name);
    long limit = fpathconf(parent, _PC_NAME_MAX);
    size_t capacity = limit > 0 && (size_t)limit < length + 16 ? (size_t)limit : length + 16;
    char *alternate = malloc(capacity + 1);
    if (!alternate) return AU_NOMEM;
    const char *extension = strrchr(name, '.');
    if (!extension || extension == name) extension = name + length;
    size_t extension_length = strlen(extension);
    au_status status = AU_EXISTS;
    for (unsigned number = 2; status == AU_EXISTS && number <= 10000; ++number) {
        char suffix[16];
        size_t suffix_length = (size_t)snprintf(suffix, sizeof(suffix), " (%u)", number);
        if (capacity <= suffix_length) { status = AU_IO; break; }
        if (capacity - suffix_length <= extension_length) {
            extension = name + length;
            extension_length = 0;
        }
        size_t stem = (size_t)(extension - name);
        size_t max_stem = capacity - suffix_length - extension_length;
        if (stem > max_stem) {
            stem = max_stem;
            while (stem && ((unsigned char)name[stem] & 0xc0) == 0x80) --stem;
        }
        memcpy(alternate, name, stem);
        memcpy(alternate + stem, suffix, suffix_length);
        memcpy(alternate + stem + suffix_length, extension, extension_length + 1);
        status = au_publish_exclusive(parent, temporary, alternate);
    }
    free(alternate);
    return status;
}

static au_status publish(int parent, char *temporary, const char *name, uint32_t policy,
                         const au_source *source) {
    int exists;
    if (policy == AU_CONFLICT_REPLACE) {
        au_status status = existing_file(parent, name, &exists, source);
        if (status != AU_OK) return status;
        return renameat(parent, temporary, parent, name) ? au_output_error(errno) : AU_OK;
    }
    au_status status = au_publish_exclusive(parent, temporary, name);
    if (status != AU_EXISTS || policy == AU_CONFLICT_FAIL) return status;
    status = existing_file(parent, name, &exists, NULL);
    if (status != AU_OK) return status;
    if (policy == AU_CONFLICT_SKIP) return AU_END;
    return publish_numbered(parent, temporary, name);
}

static au_status write_file(au_archive *archive, const au_source *source, int parent, const char *name,
                            uint64_t *written, uint64_t done) {
    const au_options *options = &archive->options;
    if (archive->entry.size_known &&
        (archive->entry.size > options->max_entry_bytes ||
         archive->entry.size > archive->max_total - archive->total_bytes)) return AU_LIMIT;
    int exists;
    uint32_t policy = options->conflict_policy;
    au_status status = existing_file(parent, name, &exists, policy == AU_CONFLICT_REPLACE ? source : NULL);
    if (status != AU_OK) return status;
    if (exists && policy == AU_CONFLICT_FAIL) return AU_EXISTS;
    if (exists && policy == AU_CONFLICT_SKIP) return AU_OK;

    char temporary[96];
    int fd = au_open_temp(parent, name, temporary, sizeof(temporary), O_WRONLY);
    if (fd < 0) return au_output_error(errno);
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
    if (close(fd) && status == AU_OK) status = au_output_error(errno);
    if (status == AU_OK && au_cancelled(options)) status = AU_CANCELLED;
    if (status == AU_OK) status = publish(parent, temporary, name, policy, source);
    if (temporary[0] && unlinkat(parent, temporary, 0) && errno != ENOENT &&
        (status == AU_OK || status == AU_END)) status = AU_IO;
    if (status == AU_OK) *written += staged;
    return status == AU_END ? AU_OK : status;
}

static au_status output_path(const au_entry *entry, uint32_t max_depth, const char *component,
                             size_t component_length, const char **name, size_t *length) {
    au_status status = au_normalize_path(entry->name, entry->kind, max_depth, name, length);
    if (status != AU_OK || !component) return status;
    if (*length < component_length || memcmp(*name, component, component_length)) return AU_INVALID;
    if (*length == component_length) return entry->kind == AU_ENTRY_DIRECTORY ? AU_END : AU_INVALID;
    if ((*name)[component_length] != '/') return AU_INVALID;
    *name += component_length + 1;
    *length -= component_length + 1;
    return AU_OK;
}

static au_status check_root(const au_context *context, au_source *source, const char *hint,
                            const uint64_t *selection, size_t selection_count, const char *component,
                            size_t component_length, const au_options *options) {
    au_archive *catalog = NULL;
    au_status status = aether_unzip_archive_open_catalog(context, source, hint, options, &catalog);
    if (status != AU_OK) return status;
    int matched = 0;
    size_t selected = 0;
    const au_entry *entry;
    while ((status = aether_unzip_archive_next_entry(catalog, &entry)) == AU_OK) {
        if (selection && entry->index != selection[selected]) continue;
        if (entry->kind == AU_ENTRY_OTHER) { status = AU_UNSUPPORTED; break; }
        const char *name = NULL;
        size_t length;
        status = output_path(entry, catalog->options.max_path_depth, component, component_length, &name, &length);
        if (status != AU_OK && status != AU_END) break;
        if (name) matched = 1;
        if (selection && ++selected == selection_count) break;
    }
    if (status == AU_OK || status == AU_END) {
        if (selection && selected != selection_count) status = AU_NOT_FOUND;
        else status = matched ? AU_OK : AU_INVALID;
    }
    aether_unzip_archive_close(catalog);
    return status;
}

au_status aether_unzip_extract_stripping_root(const au_context *context, au_source *source,
                                             const char *name_hint, const char *directory,
                                             const uint64_t *selection, size_t selection_count,
                                             const char *component, const au_options *options) {
    if (!directory || (!selection && selection_count) || (selection && !selection_count))
        return AU_INVALID;
    for (size_t i = 1; i < selection_count; ++i)
        if (selection[i] <= selection[i - 1]) return AU_INVALID;

    size_t component_length = 0;
    if (component) {
        const char *normalized;
        au_status status = aether_unzip_normalize_entry_path(component, AU_ENTRY_FILE, 1,
                                                             &normalized, &component_length);
        if (status != AU_OK || normalized != component || !au_valid_utf8(component)) return AU_INVALID;
        status = check_root(context, source, name_hint, selection, selection_count, component,
                            component_length, options);
        if (status != AU_OK) return status;
    }

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
        const char *name;
        size_t length;
        status = output_path(entry, archive->options.max_path_depth, component, component_length, &name, &length);
        if (status == AU_OK) {
            int parent;
            char *leaf;
            status = au_safe_parent(root, name, length, &parent, &leaf);
            if (status == AU_OK) {
                status = entry->kind == AU_ENTRY_DIRECTORY ? make_directory(parent, leaf) :
                    write_file(archive, source, parent, leaf, &written, done);
                free(leaf);
                if (parent != root) close(parent);
            }
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

au_status aether_unzip_extract(const au_context *context, au_source *source, const char *name_hint,
                               const char *directory, const uint64_t *selection,
                               size_t selection_count, const au_options *options) {
    return aether_unzip_extract_stripping_root(context, source, name_hint, directory, selection,
                                              selection_count, NULL, options);
}
