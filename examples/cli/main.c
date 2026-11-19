#include <aetherunzip/api.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static au_status list_directory(au_resource_mount *mount, const char *path) {
    au_resource_directory *directory = NULL;
    au_status status = aether_unzip_resource_directory_open(mount, path, &directory);
    if (status != AU_OK) return status;
    const au_entry *entry;
    while ((status = aether_unzip_resource_directory_next(directory, &entry)) == AU_OK) {
        if (printf("%s%s\n", entry->name, entry->kind == AU_ENTRY_DIRECTORY ? "/" : "") < 0) {
            status = AU_IO;
            break;
        }
    }
    aether_unzip_resource_directory_close(directory);
    return status == AU_END ? AU_OK : status;
}

static au_status print_file(const au_resource_mount *mount, const char *path) {
    au_resource_file *file = NULL;
    au_status status = aether_unzip_resource_open_path(mount, path, &file);
    if (status != AU_OK) return status;

    unsigned char bytes[16384];
    for (;;) {
        size_t count;
        status = aether_unzip_resource_read(file, bytes, sizeof(bytes), &count);
        if (status != AU_OK || !count) break;
        if (fwrite(bytes, 1, count, stdout) != count) {
            status = AU_IO;
            break;
        }
    }
    aether_unzip_resource_close(file);
    return status;
}

static au_status read_resource(const au_context *context, au_source *source,
                               const char *hint, const char *path, int list) {
    au_resource_mount *mount = NULL;
    au_status status = aether_unzip_resource_mount(context, source, hint, NULL, &mount);
    if (status == AU_OK) status = aether_unzip_resource_build_index(mount, 16 * 1024 * 1024);
    if (status == AU_OK) status = list ? list_directory(mount, path) : print_file(mount, path);
    aether_unzip_resource_unmount(mount);
    if (status == AU_OK && fflush(stdout) != 0) status = AU_IO;
    return status;
}

int main(int argc, char **argv) {
    int cat = argc == 4 && !strcmp(argv[1], "--cat");
    int list = argc == 4 && !strcmp(argv[1], "--ls");
    if (argc < 2 || (argc > 3 && !cat && !list)) {
        fprintf(stderr, "Usage: %s ARCHIVE [EXISTING_OUTPUT_DIRECTORY]\n"
                        "       %s --cat ARCHIVE RESOURCE_PATH\n"
                        "       %s --ls ARCHIVE DIRECTORY_PATH\n", argv[0], argv[0], argv[0]);
        return 2;
    }
    const char *input = argv[cat || list ? 2 : 1];
    au_context *context = NULL;
    au_source *source = NULL;
    au_archive *archive = NULL;
    au_status status = aether_unzip_context_create(&context);
    if (status == AU_OK) status = aether_unzip_source_file(input, &source);
    if (status == AU_OK && (cat || list)) {
        status = read_resource(context, source, input, argv[3], list);
    } else if (status == AU_OK && argc == 3) {
        status = aether_unzip_extract(context, source, input, argv[2], NULL, 0, NULL);
    } else if (status == AU_OK) {
        status = aether_unzip_archive_open(context, source, input, NULL, &archive);
        if (status == AU_OK) {
            const au_probe_result *info = aether_unzip_archive_info(archive);
            printf("%s\n", aether_unzip_format_name(info->format));
            const au_entry *entry;
            while ((status = aether_unzip_archive_next_entry(archive, &entry)) == AU_OK) {
                if (entry->size_known) printf("%12" PRIu64 "  ", entry->size);
                else printf("%12s  ", "?");
                printf("%s\n", entry->name);
            }
            if (status == AU_END) status = AU_OK;
        }
    }
    aether_unzip_archive_close(archive);
    aether_unzip_source_close(source);
    aether_unzip_context_destroy(context);
    if (status != AU_OK) {
        const char *message = (cat || list) && status == AU_EXISTS ? "Ambiguous resource path"
                                                                   : aether_unzip_error_message(status);
        fprintf(stderr, "%s\n", message);
    }
    return status != AU_OK;
}
