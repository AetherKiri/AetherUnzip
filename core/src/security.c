#include "internal.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int au_valid_utf8(const char *text) {
    const unsigned char *p = (const unsigned char *)text;
    while (*p) {
        unsigned c = *p++;
        if (c < 0x80) continue;
        unsigned count, minimum;
        if (c >= 0xc2 && c <= 0xdf) { count = 1; minimum = 0x80; c &= 0x1f; }
        else if (c <= 0xef && c >= 0xe0) { count = 2; minimum = 0x800; c &= 0xf; }
        else if (c <= 0xf4 && c >= 0xf0) { count = 3; minimum = 0x10000; c &= 7; }
        else return 0;
        while (count--) {
            if ((*p & 0xc0) != 0x80) return 0;
            c = (c << 6) | (*p++ & 0x3f);
        }
        if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return 0;
    }
    return 1;
}

static int open_directory(int parent, const char *name) {
    if (mkdirat(parent, name, 0700) && errno != EEXIST) return -1;
    return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

int au_open_temp(int parent, const char *reserved, char *name, size_t capacity, int access) {
    static atomic_uint_fast64_t counter;
    for (int attempt = 0; attempt < 128; ++attempt) {
        uint_fast64_t id = atomic_fetch_add_explicit(&counter, 1, memory_order_relaxed);
        int length = snprintf(name, capacity, ".aetherunzip-%ld-%" PRIuFAST64, (long)getpid(), id);
        if (length < 0 || (size_t)length >= capacity) return -1;
        if (reserved && !strcmp(name, reserved)) continue;
        int fd = openat(parent, name, access | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd >= 0 || errno != EEXIST) return fd;
    }
    return -1;
}

au_status au_normalize_path(const char *name, uint32_t kind, uint32_t max_depth,
                            const char **normalized, size_t *normalized_length) {
    if (!*name || *name == '/' || strchr(name, '\\') || strchr(name, ':')) return AU_UNSAFE_PATH;
    while (name[0] == '.' && name[1] == '/') name += 2;
    size_t length = strlen(name);
    if (length && name[length - 1] == '/' && kind == AU_ENTRY_DIRECTORY) --length;
    if ((!length || (length == 1 && *name == '.')) && kind == AU_ENTRY_DIRECTORY)
        return AU_END;
    if (!length) return AU_UNSAFE_PATH;

    uint32_t depth = 0;
    for (size_t start = 0, end = 0; end <= length; ++end) {
        if (end != length && name[end] != '/') continue;
        size_t count = end - start;
        if (!count || (count == 1 && name[start] == '.') ||
            (count == 2 && !memcmp(name + start, "..", 2))) return AU_UNSAFE_PATH;
        if (depth == max_depth) return AU_LIMIT;
        ++depth;
        start = end + 1;
    }
    *normalized = name;
    *normalized_length = length;
    return AU_OK;
}

au_status au_safe_parent(int root, const au_entry *entry, uint32_t max_depth,
                         int *parent, char **leaf) {
    const char *name;
    size_t length;
    au_status status = au_normalize_path(entry->name, entry->kind, max_depth, &name, &length);
    if (status != AU_OK) return status;
    char *path = strndup(name, length);
    if (!path) return AU_NOMEM;
    int current = fcntl(root, F_DUPFD_CLOEXEC, 0);
    if (current < 0) {
        free(path);
        return AU_IO;
    }
    char *component = path;
    char *separator;
    while ((separator = strchr(component, '/'))) {
        *separator = '\0';
        int child = open_directory(current, component);
        int error = errno;
        close(current);
        if (child < 0) {
            free(path);
            return error == ENOTDIR || error == ELOOP ? AU_UNSAFE_PATH : AU_IO;
        }
        current = child;
        component = separator + 1;
    }
    memmove(path, component, strlen(component) + 1);
    *parent = current;
    *leaf = path;
    return AU_OK;
}

au_status au_write_all(int fd, const void *data, size_t size) {
    const unsigned char *bytes = data;
    while (size) {
        ssize_t n = write(fd, bytes, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return AU_IO;
        bytes += n;
        size -= (size_t)n;
    }
    return AU_OK;
}
