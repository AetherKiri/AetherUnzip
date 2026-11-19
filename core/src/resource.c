#include "internal.h"
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    au_resource_mount *mount;
    uint64_t index;
} origin;

struct au_resource_mount {
    atomic_uint refs;
    au_archive *archive;
    au_source *source;
    au_context *context;
    char *hint;
    au_entry *entries;
    size_t entry_count;
    size_t name_bytes;
    int indexed;
    int composed;
    au_options composition_options;
    origin *origins;
    size_t enumeration_index;
    uint32_t depth;
    au_nested_limits nested_limits;
    uint64_t staged_bytes;
};
struct au_resource_file {
    au_archive *archive;
    au_entry virtual_entry;
};
struct au_resource_directory {
    au_resource_mount *mount;
    size_t current;
    size_t end;
    size_t prefix_length;
    au_entry implicit;
    char *name;
};

typedef struct {
    au_entry entry;
    origin source;
    size_t layer;
} composition_entry;

typedef struct {
    composition_entry *entries;
    size_t count, capacity, max_entries, name_bytes;
    const au_options *options;
} composition_builder;

static void free_entries(au_entry *entries, size_t count) {
    for (size_t i = 0; i < count; ++i) free((void *)entries[i].name);
    free(entries);
}

static const au_options *mount_options(const au_resource_mount *mount) {
    return mount->composed ? &mount->composition_options : &mount->archive->options;
}

static void retain_mount(au_resource_mount *mount) {
    atomic_fetch_add_explicit(&mount->refs, 1, memory_order_relaxed);
}

static origin get_origin(const au_resource_mount *mount, uint64_t index) {
    if (mount->composed) return mount->origins[index];
    return (origin){(au_resource_mount *)mount, index};
}

static int compare_composition_entries(const void *left, const void *right) {
    const composition_entry *a = left, *b = right;
    int order = strcmp(a->entry.name, b->entry.name);
    if (order) return order;
    if (a->layer != b->layer) return a->layer < b->layer ? -1 : 1;
    return (a->entry.index > b->entry.index) - (a->entry.index < b->entry.index);
}

static au_status add_composition_entry(composition_builder *builder, const au_entry *entry,
                                       origin source, size_t layer, const char *prefix,
                                       size_t prefix_length) {
    if (builder->count == builder->max_entries ||
        entry->name_length >= builder->name_bytes ||
        prefix_length >= builder->name_bytes - entry->name_length) return AU_LIMIT;
    if (builder->count == builder->capacity) {
        size_t next = builder->capacity > builder->max_entries / 2
            ? builder->max_entries : builder->capacity * 2;
        if (!next) next = 1;
        composition_entry *entries = realloc(builder->entries, next * sizeof(*entries));
        if (!entries) return AU_NOMEM;
        builder->entries = entries;
        builder->capacity = next;
    }
    size_t length = prefix_length + entry->name_length;
    char *name = malloc(length + 1);
    if (!name) return AU_NOMEM;
    if (prefix_length) {
        memcpy(name, prefix, prefix_length - 1);
        name[prefix_length - 1] = '/';
    }
    memcpy(name + prefix_length, entry->name, entry->name_length);
    name[length] = '\0';
    const char *normalized;
    size_t normalized_length;
    au_status status = au_normalize_path(name, entry->kind, builder->options->max_path_depth,
                                         &normalized, &normalized_length);
    if (status != AU_OK) {
        free(name);
        return status;
    }
    composition_entry *record = &builder->entries[builder->count++];
    *record = (composition_entry){.entry = *entry, .source = source, .layer = layer};
    record->entry.name = name;
    record->entry.name_length = length;
    builder->name_bytes -= length + 1;
    return AU_OK;
}

static au_status add_layer(composition_builder *builder, const au_resource_layer *layer,
                           size_t ordinal) {
    if (layer->struct_size < sizeof(*layer) || !layer->mount) return AU_INVALID;
    const au_resource_mount *mount = layer->mount;
    if (!mount->indexed) return AU_UNSUPPORTED;
    const char *prefix = layer->prefix;
    size_t length = 0;
    if (prefix && *prefix) {
        if (!au_valid_utf8(prefix)) return AU_INVALID;
        au_status status = au_normalize_path(prefix, AU_ENTRY_DIRECTORY,
            builder->options->max_path_depth, &prefix, &length);
        if (status != AU_OK && status != AU_END) return status;
        if (status == AU_OK) {
            au_entry directory = {.struct_size = sizeof(directory), .kind = AU_ENTRY_DIRECTORY,
                                  .name = prefix, .name_length = length, .index = UINT64_MAX};
            status = add_composition_entry(builder, &directory, (origin){0}, ordinal, NULL, 0);
            if (status != AU_OK) return status;
        }
    }
    for (size_t i = 0; i < mount->entry_count; ++i) {
        if (au_cancelled(builder->options)) return AU_CANCELLED;
        const au_entry *entry = &mount->entries[i];
        origin source = entry->kind == AU_ENTRY_FILE ? get_origin(mount, entry->index) : (origin){0};
        au_status status = add_composition_entry(builder, entry, source, ordinal,
                                                  prefix, length ? length + 1 : 0);
        if (status != AU_OK) return status;
    }
    return AU_OK;
}

static void publish_composition(au_resource_mount *mount, composition_builder *builder,
                                uint32_t collision_policy) {
    composition_entry *entries = builder->entries;
    for (size_t first = 0; first < builder->count;) {
        size_t end = first + 1;
        int files = entries[first].entry.kind == AU_ENTRY_FILE;
        int directories = !files;
        int duplicate_directory = 0;
        while (end < builder->count && !strcmp(entries[first].entry.name, entries[end].entry.name)) {
            int is_file = entries[end].entry.kind == AU_ENTRY_FILE;
            files |= is_file;
            directories |= !is_file;
            if (!is_file && entries[end - 1].entry.kind == AU_ENTRY_DIRECTORY &&
                entries[end - 1].layer == entries[end].layer) duplicate_directory = 1;
            ++end;
        }
        size_t selected = first, selected_end = end;
        if (!files && !duplicate_directory) selected_end = first + 1;
        if (!directories && collision_policy == AU_RESOURCE_PREFER_LAST) {
            selected = end - 1;
            while (selected > first && entries[selected - 1].layer == entries[end - 1].layer)
                --selected;
        }
        for (size_t i = selected; i < selected_end; ++i) {
            size_t index = mount->entry_count++;
            mount->entries[index] = entries[i].entry;
            mount->entries[index].index = index;
            mount->name_bytes += entries[i].entry.name_length + 1;
            mount->origins[index] = entries[i].source;
            if (entries[i].source.mount) retain_mount(entries[i].source.mount);
            entries[i].entry.name = NULL;
        }
        first = end;
    }
}

au_status aether_unzip_resource_compose(const au_resource_layer *layers, size_t count,
    uint32_t collision_policy, size_t max_name_bytes, const au_options *options,
    au_resource_mount **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!layers || !count || count > SIZE_MAX / sizeof(*layers) ||
        collision_policy > AU_RESOURCE_PREFER_LAST) return AU_INVALID;
    au_options resolved;
    au_status status = au_options_resolve(options, &resolved);
    if (status != AU_OK) return status;
    size_t max_entries = SIZE_MAX / sizeof(composition_entry);
    if (resolved.max_entries < max_entries) max_entries = (size_t)resolved.max_entries;
    composition_builder builder = {.max_entries = max_entries, .name_bytes = max_name_bytes,
                                   .options = &resolved};
    for (size_t i = 0; i < count; ++i) {
        if (au_cancelled(&resolved)) { status = AU_CANCELLED; break; }
        status = add_layer(&builder, &layers[i], i);
        if (status != AU_OK) break;
    }
    au_resource_mount *mount = NULL;
    if (status == AU_OK) {
        mount = calloc(1, sizeof(*mount));
        if (!mount) status = AU_NOMEM;
    }
    if (mount) {
        atomic_init(&mount->refs, 1);
        mount->indexed = mount->composed = 1;
        mount->composition_options = resolved;
        if (builder.count) {
            mount->entries = calloc(builder.count, sizeof(*mount->entries));
            mount->origins = calloc(builder.count, sizeof(*mount->origins));
            if (!mount->entries || !mount->origins) status = AU_NOMEM;
        }
        if (status == AU_OK) {
            if (builder.count > 1)
                qsort(builder.entries, builder.count, sizeof(*builder.entries), compare_composition_entries);
            publish_composition(mount, &builder, collision_policy);
            if (au_cancelled(&resolved)) status = AU_CANCELLED;
        }
    }
    for (size_t i = 0; i < builder.count; ++i) free((void *)builder.entries[i].entry.name);
    free(builder.entries);
    if (status == AU_OK) *out = mount;
    else aether_unzip_resource_unmount(mount);
    return status;
}

au_status aether_unzip_resource_mount(const au_context *context, au_source *source,
                                      const char *name_hint, const au_options *options,
                                      au_resource_mount **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    au_resource_mount *mount = calloc(1, sizeof(*mount));
    if (!mount) return AU_NOMEM;
    atomic_init(&mount->refs, 1);
    au_status status = aether_unzip_archive_open(context, source, name_hint, options,
                                                &mount->archive);
    if (status == AU_OK && name_hint) {
        mount->hint = strdup(name_hint);
        if (!mount->hint) status = AU_NOMEM;
    }
    if (status != AU_OK) {
        aether_unzip_resource_unmount(mount);
        return status;
    }
    mount->source = source;
    mount->context = (au_context *)context;
    au_source_retain(source);
    au_context_retain(context);
    *out = mount;
    return AU_OK;
}

void aether_unzip_resource_unmount(au_resource_mount *mount) {
    if (!mount || atomic_fetch_sub_explicit(&mount->refs, 1, memory_order_acq_rel) != 1) return;
    aether_unzip_archive_close(mount->archive);
    aether_unzip_source_close(mount->source);
    aether_unzip_context_destroy(mount->context);
    if (mount->origins) {
        for (size_t i = 0; i < mount->entry_count; ++i)
            aether_unzip_resource_unmount(mount->origins[i].mount);
    }
    free(mount->origins);
    free_entries(mount->entries, mount->entry_count);
    free(mount->hint);
    free(mount);
}
const au_probe_result *aether_unzip_resource_info(const au_resource_mount *mount) {
    return mount ? aether_unzip_archive_info(mount->archive) : NULL;
}

au_status aether_unzip_resource_source(const au_resource_mount *mount, au_source **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!mount) return AU_INVALID;
    if (mount->composed) return AU_UNSUPPORTED;
    au_source_retain(mount->source);
    *out = mount->source;
    return AU_OK;
}
au_status aether_unzip_resource_next(au_resource_mount *mount, const au_entry **entry) {
    if (!mount || !entry) return AU_INVALID;
    if (!mount->composed) return aether_unzip_archive_next_entry(mount->archive, entry);
    *entry = NULL;
    if (au_cancelled(mount_options(mount))) return AU_CANCELLED;
    if (mount->enumeration_index == mount->entry_count) return AU_END;
    *entry = &mount->entries[mount->enumeration_index++];
    return AU_OK;
}

static au_status open_cursor(const au_resource_mount *mount, au_archive **archive) {
    return aether_unzip_archive_open(mount->context, mount->source, mount->hint,
                                    &mount->archive->options, archive);
}

static int compare_entries(const void *left, const void *right) {
    const au_entry *a = left, *b = right;
    return strcmp(a->name, b->name);
}

au_status aether_unzip_resource_build_index(au_resource_mount *mount, size_t max_name_bytes) {
    if (!mount) return AU_INVALID;
    if (mount->indexed) return AU_OK;
    au_archive *cursor = NULL;
    au_status status = open_cursor(mount, &cursor);
    if (status != AU_OK) return status;

    au_entry *entries = NULL;
    size_t count = 0, capacity = 0;
    size_t name_budget = max_name_bytes;
    size_t max_capacity = SIZE_MAX / sizeof(*entries);
    if (cursor->options.max_entries < max_capacity) max_capacity = (size_t)cursor->options.max_entries;
    const au_entry *entry;
    while ((status = aether_unzip_archive_next_entry(cursor, &entry)) == AU_OK) {
        if (entry->kind != AU_ENTRY_FILE && entry->kind != AU_ENTRY_DIRECTORY) continue;
        const char *name;
        size_t length;
        status = au_normalize_path(entry->name, entry->kind, cursor->options.max_path_depth,
                                   &name, &length);
        if (status == AU_END || status == AU_UNSAFE_PATH) continue;
        if (status != AU_OK) break;
        if (length >= max_name_bytes || count == max_capacity) {
            status = AU_LIMIT;
            break;
        }
        if (count == capacity) {
            size_t next = capacity > max_capacity / 2 ? max_capacity : capacity * 2;
            if (!next) next = 1;
            au_entry *grown = realloc(entries, next * sizeof(*entries));
            if (!grown) { status = AU_NOMEM; break; }
            entries = grown;
            capacity = next;
        }
        char *copy = strndup(name, length);
        if (!copy) { status = AU_NOMEM; break; }
        entries[count] = *entry;
        entries[count].name = copy;
        entries[count].name_length = length;
        ++count;
        max_name_bytes -= length + 1;
    }
    aether_unzip_archive_close(cursor);
    if (status != AU_END) {
        free_entries(entries, count);
        return status;
    }
    if (count > 1) qsort(entries, count, sizeof(*entries), compare_entries);
    if (au_cancelled(mount_options(mount))) {
        free_entries(entries, count);
        return AU_CANCELLED;
    }
    mount->entries = entries;
    mount->entry_count = count;
    mount->name_bytes = name_budget - max_name_bytes;
    mount->indexed = 1;
    return AU_OK;
}

au_status aether_unzip_resource_index_size(const au_resource_mount *mount, size_t *entry_count,
                                           size_t *name_bytes) {
    if (!mount || !entry_count || !name_bytes) return AU_INVALID;
    *entry_count = *name_bytes = 0;
    if (!mount->indexed) return AU_UNSUPPORTED;
    *entry_count = mount->entry_count;
    *name_bytes = mount->name_bytes;
    return AU_OK;
}

static int compare_path(const au_entry *entry, const char *name, size_t length, char suffix) {
    size_t common = entry->name_length < length ? entry->name_length : length;
    int order = memcmp(entry->name, name, common);
    if (order) return order;
    if (entry->name_length < length) return -1;
    if (suffix) {
        order = (unsigned char)entry->name[length] - (unsigned char)suffix;
        if (order) return order;
        ++length;
    }
    return entry->name_length > length;
}

static size_t first_entry(const au_resource_mount *mount, const char *name, size_t length,
                          char suffix) {
    size_t lower = 0, upper = mount->entry_count;
    while (lower < upper) {
        size_t mid = lower + (upper - lower) / 2;
        if (compare_path(&mount->entries[mid], name, length, suffix) < 0) lower = mid + 1;
        else upper = mid;
    }
    return lower;
}

static int matches(const au_resource_mount *mount, size_t index, const char *name, size_t length) {
    return index < mount->entry_count && !compare_path(&mount->entries[index], name, length, 0);
}

static size_t first_outside_directory(const au_resource_mount *mount, const char *path,
                                      size_t length) {
    return first_entry(mount, path, length, '/' + 1);
}

static int has_descendants(const au_resource_mount *mount, const char *path, size_t length) {
    return first_entry(mount, path, length, '/') < first_outside_directory(mount, path, length);
}

static au_status check_ancestors(const au_resource_mount *mount, const char *path, size_t length) {
    const char *slash = memchr(path, '/', length);
    while (slash) {
        size_t prefix = (size_t)(slash - path);
        size_t exact = first_entry(mount, path, prefix, 0);
        if (matches(mount, exact, path, prefix) &&
            (mount->entries[exact].kind != AU_ENTRY_DIRECTORY ||
             matches(mount, exact + 1, path, prefix))) return AU_EXISTS;
        slash = memchr(slash + 1, '/', length - prefix - 1);
    }
    return AU_OK;
}

au_status aether_unzip_resource_lookup(const au_resource_mount *mount, const char *path,
                                       const au_entry **entry) {
    if (!entry) return AU_INVALID;
    *entry = NULL;
    if (!mount || !path || !au_valid_utf8(path)) return AU_INVALID;
    if (!mount->indexed) return AU_UNSUPPORTED;
    size_t input_length = strlen(path);
    int directory = input_length && path[input_length - 1] == '/';
    const char *name;
    size_t length;
    au_status status = au_normalize_path(path, directory ? AU_ENTRY_DIRECTORY : AU_ENTRY_FILE,
                                        mount_options(mount)->max_path_depth, &name, &length);
    if (status == AU_END) return AU_NOT_FOUND;
    if (status != AU_OK) return status;
    status = check_ancestors(mount, name, length);
    if (status != AU_OK) return status;

    size_t lower = first_entry(mount, name, length, 0);
    if (!matches(mount, lower, name, length)) return AU_NOT_FOUND;
    if (matches(mount, lower + 1, name, length)) return AU_EXISTS;
    const au_entry *match = &mount->entries[lower];
    if (match->kind == AU_ENTRY_FILE && has_descendants(mount, name, length)) return AU_EXISTS;
    if (directory && match->kind != AU_ENTRY_DIRECTORY) return AU_NOT_FOUND;
    *entry = match;
    return AU_OK;
}

au_status aether_unzip_resource_directory_open(au_resource_mount *mount, const char *path,
                                               au_resource_directory **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!mount || !path || !au_valid_utf8(path)) return AU_INVALID;
    if (!mount->indexed) return AU_UNSUPPORTED;

    size_t start = 0, end = mount->entry_count, prefix_length = 0;
    if (*path) {
        const char *name;
        size_t length;
        au_status status = au_normalize_path(path, AU_ENTRY_DIRECTORY,
            mount_options(mount)->max_path_depth, &name, &length);
        if (status != AU_OK) return status == AU_END ? AU_UNSAFE_PATH : status;
        status = check_ancestors(mount, name, length);
        if (status != AU_OK) return status;
        size_t exact = first_entry(mount, name, length, 0);
        start = first_entry(mount, name, length, '/');
        end = first_outside_directory(mount, name, length);
        if (matches(mount, exact, name, length)) {
            if (matches(mount, exact + 1, name, length)) return AU_EXISTS;
            if (mount->entries[exact].kind != AU_ENTRY_DIRECTORY)
                return start < end ? AU_EXISTS : AU_UNSUPPORTED;
        } else if (start == end) {
            return AU_NOT_FOUND;
        }
        prefix_length = length + 1;
    }
    au_resource_directory *directory = calloc(1, sizeof(*directory));
    if (!directory) return AU_NOMEM;
    retain_mount(mount);
    directory->mount = mount;
    directory->current = start;
    directory->end = end;
    directory->prefix_length = prefix_length;
    *out = directory;
    return AU_OK;
}

au_status aether_unzip_resource_directory_next(au_resource_directory *directory,
                                               const au_entry **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!directory) return AU_INVALID;
    const au_resource_mount *mount = directory->mount;
    if (au_cancelled(mount_options(mount))) return AU_CANCELLED;
    while (directory->current < directory->end) {
        const au_entry *entry = &mount->entries[directory->current];
        const char *slash = strchr(entry->name + directory->prefix_length, '/');
        if (slash) {
            size_t length = (size_t)(slash - entry->name);
            size_t end = first_outside_directory(mount, entry->name, length);
            size_t exact = first_entry(mount, entry->name, length, 0);
            if (matches(mount, exact, entry->name, length)) {
                // The explicit child sorts earlier than this group of descendants.
                directory->current = end;
                continue;
            }
            char *name = strndup(entry->name, length);
            if (!name) return AU_NOMEM;
            free(directory->name);
            directory->name = name;
            directory->current = end;
            directory->implicit = (au_entry){.struct_size = sizeof(au_entry),
                .kind = AU_ENTRY_DIRECTORY, .index = UINT64_MAX, .name = name, .name_length = length};
            *out = &directory->implicit;
            return AU_OK;
        }

        size_t current = directory->current++;
        while (matches(mount, directory->current, entry->name, entry->name_length))
            ++directory->current;
        if (directory->current - current > 1) return AU_EXISTS;
        if (entry->kind == AU_ENTRY_FILE && has_descendants(mount, entry->name, entry->name_length))
            return AU_EXISTS;
        *out = entry;
        return AU_OK;
    }
    return AU_END;
}

void aether_unzip_resource_directory_close(au_resource_directory *directory) {
    if (!directory) return;
    aether_unzip_resource_unmount(directory->mount);
    free(directory->name);
    free(directory);
}

au_status aether_unzip_resource_open(const au_resource_mount *mount, uint64_t index,
                                     au_resource_file **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!mount) return AU_INVALID;
    if (mount->composed) {
        if (au_cancelled(mount_options(mount))) return AU_CANCELLED;
        if (index >= mount->entry_count) return AU_NOT_FOUND;
        const au_entry *entry = &mount->entries[index];
        origin source = get_origin(mount, index);
        if (!source.mount) return AU_UNSUPPORTED;
        au_resource_file *file = NULL;
        au_status status = aether_unzip_resource_open(source.mount, source.index, &file);
        if (status != AU_OK) return status;
        char *name = strdup(entry->name);
        if (!name) {
            aether_unzip_resource_close(file);
            return AU_NOMEM;
        }
        file->virtual_entry = *entry;
        file->virtual_entry.name = name;
        *out = file;
        return AU_OK;
    }
    au_resource_file *file = calloc(1, sizeof(*file));
    if (!file) return AU_NOMEM;
    au_status status = open_cursor(mount, &file->archive);
    if (status == AU_OK) {
        const au_entry *entry;
        do { status = aether_unzip_archive_next_entry(file->archive, &entry); }
        while (status == AU_OK && entry->index < index);
        if (status == AU_END) status = AU_NOT_FOUND;
        if (status == AU_OK && entry->kind != AU_ENTRY_FILE) status = AU_UNSUPPORTED;
        if (status == AU_OK) status = au_archive_entry_access(file->archive);
    }
    if (status != AU_OK) {
        aether_unzip_resource_close(file);
        return status;
    }
    *out = file;
    return AU_OK;
}

au_status aether_unzip_resource_open_path(const au_resource_mount *mount, const char *path,
                                          au_resource_file **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    const au_entry *entry;
    au_status status = aether_unzip_resource_lookup(mount, path, &entry);
    if (status != AU_OK) return status;
    if (entry->kind != AU_ENTRY_FILE) return AU_UNSUPPORTED;
    return aether_unzip_resource_open(mount, entry->index, out);
}

static au_status stage_nested(au_resource_file *file, const char *scratch_directory,
                             uint64_t budget, au_source **out, uint64_t *staged) {
    int directory = open(scratch_directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return errno == ELOOP || errno == ENOTDIR ? AU_UNSAFE_PATH : AU_IO;
    char name[96];
    int fd = au_open_temp(directory, NULL, name, sizeof(name), O_RDWR);
    int unlink_result = -1;
    if (fd >= 0) {
        do { unlink_result = unlinkat(directory, name, 0); } while (unlink_result && errno == EINTR);
    }
    close(directory);
    if (fd < 0) return AU_IO;
    if (unlink_result) {
        close(fd);
        return AU_IO;
    }

    au_status status;
    unsigned char buffer[65536];
    size_t count;
    *staged = 0;
    while ((status = aether_unzip_resource_read(file, buffer, sizeof(buffer), &count)) == AU_OK && count) {
        if (count > budget - *staged) { status = AU_LIMIT; break; }
        status = au_write_all(fd, buffer, count);
        if (status != AU_OK) break;
        *staged += count;
    }
    if (status == AU_OK) status = au_source_from_fd(fd, out);
    if (status != AU_OK) close(fd);
    return status;
}

au_status aether_unzip_resource_mount_nested(const au_resource_mount *parent, const char *path,
    const char *scratch_directory, const au_context *child_context, const au_nested_limits *limits,
    au_resource_mount **out) {
    if (!out) return AU_INVALID;
    *out = NULL;
    if (!parent || !scratch_directory || !limits || limits->struct_size < sizeof(*limits) ||
        !limits->max_depth || !limits->max_staged_bytes) return AU_INVALID;

    const au_entry *entry;
    au_status status = aether_unzip_resource_lookup(parent, path, &entry);
    if (status != AU_OK) return status;
    if (entry->kind != AU_ENTRY_FILE) return AU_UNSUPPORTED;
    if (au_cancelled(mount_options(parent))) return AU_CANCELLED;
    const au_resource_mount *archive_mount = get_origin(parent, entry->index).mount;
    au_nested_limits effective = *limits;
    if (archive_mount->depth) {
        if (effective.max_depth > archive_mount->nested_limits.max_depth)
            effective.max_depth = archive_mount->nested_limits.max_depth;
        if (effective.max_staged_bytes > archive_mount->nested_limits.max_staged_bytes)
            effective.max_staged_bytes = archive_mount->nested_limits.max_staged_bytes;
    }
    if (archive_mount->depth >= effective.max_depth ||
        archive_mount->staged_bytes >= effective.max_staged_bytes)
        return AU_LIMIT;
    uint64_t budget = effective.max_staged_bytes - archive_mount->staged_bytes;
    if (entry->size_known && entry->size > budget) return AU_LIMIT;

    au_resource_file *file = NULL;
    status = aether_unzip_resource_open(parent, entry->index, &file);
    if (status != AU_OK) return status;
    au_source *source = NULL;
    uint64_t staged;
    status = stage_nested(file, scratch_directory, budget, &source, &staged);
    aether_unzip_resource_close(file);
    if (status != AU_OK) return status;

    const au_context *context = child_context ? child_context : archive_mount->context;
    status = aether_unzip_resource_mount(context, source, entry->name, mount_options(archive_mount), out);
    aether_unzip_source_close(source);
    if (status == AU_OK) {
        (*out)->depth = archive_mount->depth + 1;
        (*out)->nested_limits = effective;
        (*out)->staged_bytes = archive_mount->staged_bytes + staged;
    }
    return status;
}
const au_entry *aether_unzip_resource_file_entry(const au_resource_file *file) {
    if (!file) return NULL;
    return file->virtual_entry.name ? &file->virtual_entry : &file->archive->entry;
}
uint32_t aether_unzip_resource_file_capabilities(const au_resource_file *file) {
    return file ? AU_IO_SEQUENTIAL |
        (file->archive->entry.size_known ? AU_IO_LENGTH : 0) : 0;
}
au_status aether_unzip_resource_read(au_resource_file *file, void *buffer, size_t capacity,
                                     size_t *read_count) {
    return file ? aether_unzip_archive_read(file->archive, buffer, capacity, read_count) :
                  AU_INVALID;
}
void aether_unzip_resource_close(au_resource_file *file) {
    if (!file) return;
    aether_unzip_archive_close(file->archive);
    free((void *)file->virtual_entry.name);
    free(file);
}
