#define _POSIX_C_SOURCE 200809L
#include <aetherunzip/api.h>
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PASSWORD_LIMIT 4096
#define RESOURCE_NAME_BUDGET (16 * 1024 * 1024)

typedef enum { AUTO, PROBE, VERIFY, CAT, LIST_DIRECTORY, COMPRESS } command;

typedef struct {
    command mode;
    const char **volumes;
    size_t volume_count;
    uint64_t *entries;
    size_t entry_count;
    int password_stdin;
    int total_budget_set;
    const char *strip_root;
    au_options options;
} cli_options;

static volatile sig_atomic_t interrupted;

static void request_cancel(int signal_number) {
    (void)signal_number;
    interrupted = 1;
}

static int32_t cancelled(void *user) {
    (void)user;
    return interrupted != 0;
}

static void usage(FILE *stream, const char *program) {
    fprintf(stream, "Usage: %s [OPTIONS] ARCHIVE [EXISTING_OUTPUT_DIRECTORY]\n"
                    "       %s --probe [OPTIONS] ARCHIVE\n"
                    "       %s --verify [OPTIONS] ARCHIVE\n"
                    "       %s --cat [OPTIONS] ARCHIVE RESOURCE_PATH\n"
                    "       %s --ls [OPTIONS] ARCHIVE DIRECTORY_PATH\n"
                    "       %s --compress [OPTIONS] DIRECTORY OUTPUT NAME...\n"
                    "  Archive output suffixes: .zip, .tar, .tar.gz, .tar.zst, .xp3\n"
                    "  --volume PATH          Add the next archive volume in order; repeat as needed.\n"
                    "  --entry INDEX          Verify or extract this zero-based entry index; repeat in ascending order.\n"
                    "  --password-stdin       Read one UTF-8 line from standard input.\n"
                    "  --max-total-bytes N    Limit total decoded bytes for this operation.\n"
                    "  --strip-root NAME      Remove one shared top-level directory when extracting.\n"
                    "  --keep-both           Give incoming files a new name when a file already exists.\n"
                    "  --help                 Show this usage.\n",
                    program, program, program, program, program, program);
}

static int decimal(const char *value, uint64_t *out) {
    if (!*value || strspn(value, "0123456789") != strlen(value)) return 0;
    errno = 0;
    uintmax_t number = strtoumax(value, NULL, 10);
    if (errno == ERANGE || number > UINT64_MAX) return 0;
    *out = (uint64_t)number;
    return 1;
}

static au_status password_context(int from_stdin, au_context **context) {
    if (!from_stdin) return aether_unzip_context_create(context);
    char password[PASSWORD_LIMIT + 1];
    size_t length = 0;
    int byte;
    while ((byte = getchar()) != EOF && byte != '\n' && byte != '\0' && length < PASSWORD_LIMIT)
        password[length++] = (char)byte;
    au_status status;
    if (interrupted) status = AU_CANCELLED;
    else if (ferror(stdin)) status = AU_IO;
    else if (byte == '\0' || (byte != EOF && byte != '\n')) status = AU_INVALID;
    else {
        if (length && password[length - 1] == '\r' && byte == '\n') --length;
        password[length] = '\0';
        status = aether_unzip_context_create_with_passphrase(password, context);
    }
    volatile char *erase = password;
    for (size_t i = 0; i < sizeof(password); ++i) erase[i] = 0;
    return status;
}

static au_status open_source(const char *input, const cli_options *cli, au_source **out) {
    if (!cli->volume_count) return aether_unzip_source_file(input, out);
    size_t count = cli->volume_count + 1;
    au_source **parts = calloc(count, sizeof(*parts));
    if (!parts) return AU_NOMEM;
    au_status status = aether_unzip_source_file(input, &parts[0]);
    for (size_t i = 1; status == AU_OK && i < count; ++i)
        status = aether_unzip_source_file(cli->volumes[i - 1], &parts[i]);
    if (status == AU_OK) status = aether_unzip_source_concat(parts, count, out);
    for (size_t i = 0; i < count; ++i) aether_unzip_source_close(parts[i]);
    free(parts);
    return status;
}

/* Do not write control characters from archive paths to a terminal. */
static au_status print_name(const char *path, const char *suffix) {
    for (const unsigned char *p = (const unsigned char *)path; *p; ++p) {
        if (*p < 32 || *p == 127) {
            if (printf("\\x%02x", (unsigned)*p) < 0) return AU_IO;
        } else if (putchar(*p) == EOF) return AU_IO;
    }
    return puts(suffix) == EOF ? AU_IO : AU_OK;
}

static au_status list_directory(au_resource_mount *mount, const char *path) {
    au_resource_directory *directory = NULL;
    au_status status = aether_unzip_resource_directory_open(mount, path, &directory);
    if (status != AU_OK) return status;
    const au_entry *entry;
    while ((status = aether_unzip_resource_directory_next(directory, &entry)) == AU_OK) {
        status = print_name(entry->name, entry->kind == AU_ENTRY_DIRECTORY ? "/" : "");
        if (status != AU_OK) break;
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
                               const char *input, const char *path, const cli_options *cli) {
    au_resource_mount *mount = NULL;
    au_status status = aether_unzip_resource_mount(context, source, input, &cli->options, &mount);
    if (status == AU_OK) status = aether_unzip_resource_build_index(mount, RESOURCE_NAME_BUDGET);
    if (status == AU_OK)
        status = cli->mode == LIST_DIRECTORY ? list_directory(mount, path) : print_file(mount, path);
    aether_unzip_resource_unmount(mount);
    return status;
}

static au_status probe_archive(const au_context *context, au_source *source, const char *input) {
    au_probe_result info = {.struct_size = sizeof(info)};
    /* The probe ABI has no options and checks cancellation between calls. */
    if (cancelled(NULL)) return AU_CANCELLED;
    au_status status = aether_unzip_probe(context, source, input, &info);
    if (cancelled(NULL)) return AU_CANCELLED;
    if (printf("format=%s\nfilter=%s\nkind=%s\ncandidate=%s\nextension_hint=%s\n"
               "evidence=%" PRIu32 "\ncapabilities=%" PRIu32 "\nstatus=%" PRId32 "\n",
               aether_unzip_format_name(info.format),
               info.filter ? aether_unzip_format_name(info.filter) : "none",
               info.kind == AU_KIND_STREAM ? "stream" : info.kind == AU_KIND_CONTAINER ? "container" : "unknown",
               aether_unzip_format_name(info.candidate), aether_unzip_format_name(info.extension_hint),
               info.evidence, info.capabilities, status) < 0)
        return AU_IO;
    return status;
}

static au_status catalog_archive(const au_context *context, au_source *source, const char *input,
                                 const au_options *options) {
    au_archive *archive = NULL;
    au_status status = aether_unzip_archive_open_catalog(context, source, input, options, &archive);
    if (status != AU_OK) return status;
    if (puts(aether_unzip_format_name(aether_unzip_archive_info(archive)->format)) == EOF)
        status = AU_IO;
    while (status == AU_OK) {
        const au_entry *entry;
        status = aether_unzip_archive_next_entry(archive, &entry);
        if (status != AU_OK) break;
        int printed = entry->size_known
            ? printf("%5" PRIu64 "  %12" PRIu64 "  ", entry->index, entry->size)
            : printf("%5" PRIu64 "  %12s  ", entry->index, "?");
        status = printed < 0 ? AU_IO : print_name(entry->name, entry->encrypted ? " [encrypted]" : "");
    }
    aether_unzip_archive_close(archive);
    return status == AU_END ? AU_OK : status;
}

static au_status verify_archive(const au_context *context, au_source *source, const char *input,
                                const cli_options *cli) {
    au_archive *archive = NULL;
    au_status status = aether_unzip_archive_open(context, source, input, &cli->options, &archive);
    if (status != AU_OK) return status;
    uint64_t files = 0, bytes = 0, skipped = 0;
    size_t selected = 0;
    unsigned char block[65536];
    while (status == AU_OK) {
        const au_entry *entry;
        status = aether_unzip_archive_next_entry(archive, &entry);
        if (status != AU_OK) break;
        if (cli->entry_count && cli->entries[selected] != entry->index) continue;
        if (entry->kind != AU_ENTRY_FILE) {
            if (cli->entry_count) { status = AU_UNSUPPORTED; break; }
            if (entry->kind == AU_ENTRY_OTHER) ++skipped;
            continue;
        }
        size_t count;
        while ((status = aether_unzip_archive_read(archive, block, sizeof(block), &count)) == AU_OK && count)
            bytes += count;
        if (status != AU_OK) break;
        ++files;
        if (cli->entry_count && ++selected == cli->entry_count) break;
    }
    aether_unzip_archive_close(archive);
    if (status == AU_END) status = selected == cli->entry_count ? AU_OK : AU_NOT_FOUND;
    if (status == AU_OK &&
        printf("verified_files=%" PRIu64 "\nverified_bytes=%" PRIu64 "\nskipped_special_entries=%" PRIu64 "\n",
               files, bytes, skipped) < 0)
        return AU_IO;
    return status;
}

static int parse_options(int argc, char **argv, cli_options *cli) {
    enum { ADD_VOLUME = 1000, ADD_ENTRY, PASSWORD, MAX_TOTAL, STRIP_ROOT, KEEP_BOTH };
    static const struct option flags[] = {
        {"probe", no_argument, NULL, PROBE}, {"verify", no_argument, NULL, VERIFY},
        {"cat", no_argument, NULL, CAT}, {"ls", no_argument, NULL, LIST_DIRECTORY},
        {"compress", no_argument, NULL, COMPRESS},
        {"volume", required_argument, NULL, ADD_VOLUME}, {"entry", required_argument, NULL, ADD_ENTRY},
        {"password-stdin", no_argument, NULL, PASSWORD},
        {"strip-root", required_argument, NULL, STRIP_ROOT}, {"keep-both", no_argument, NULL, KEEP_BOTH},
        {"max-total-bytes", required_argument, NULL, MAX_TOTAL}, {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0}
    };
    opterr = 0;
    int flag;
    while ((flag = getopt_long(argc, argv, "+h", flags, NULL)) != -1) {
        switch (flag) {
        case 'h': return -1;
        case PROBE: case VERIFY: case CAT: case LIST_DIRECTORY: case COMPRESS:
            if (cli->mode != AUTO) return 0;
            cli->mode = (command)flag;
            break;
        case ADD_VOLUME:
            if (!*optarg) return 0;
            cli->volumes[cli->volume_count++] = optarg;
            break;
        case ADD_ENTRY: {
            uint64_t index;
            if (!decimal(optarg, &index) ||
                (cli->entry_count && cli->entries[cli->entry_count - 1] >= index)) return 0;
            cli->entries[cli->entry_count++] = index;
            break;
        }
        case PASSWORD:
            cli->password_stdin = 1;
            break;
        case MAX_TOTAL:
            if (!decimal(optarg, &cli->options.max_total_bytes) || !cli->options.max_total_bytes)
                return 0;
            cli->total_budget_set = 1;
            break;
        case STRIP_ROOT:
            if (!*optarg || cli->strip_root) return 0;
            cli->strip_root = optarg;
            break;
        case KEEP_BOTH:
            cli->options.conflict_policy = AU_CONFLICT_KEEP_BOTH;
            break;
        default: return 0;
        }
    }
    int operands = argc - optind;
    if (cli->strip_root || cli->options.conflict_policy == AU_CONFLICT_KEEP_BOTH)
        return cli->mode == AUTO && operands == 2;
    if (cli->mode == COMPRESS)
        return operands >= 3 && !cli->entry_count && !cli->volume_count && !cli->password_stdin;
    if (cli->mode == CAT || cli->mode == LIST_DIRECTORY)
        return operands == 2 && !cli->entry_count;
    if (cli->mode == VERIFY) return operands == 1;
    if (cli->mode == PROBE) return operands == 1 && !cli->entry_count && !cli->total_budget_set;
    return operands == 2 || (operands == 1 && !cli->entry_count);
}

int main(int argc, char **argv) {
    cli_options cli = {.options = aether_unzip_options_default(),
                       .volumes = calloc((size_t)argc, sizeof(*cli.volumes)),
                       .entries = calloc((size_t)argc, sizeof(*cli.entries))};
    au_context *context = NULL;
    au_source *source = NULL;
    au_status status = AU_NOMEM;
    int code = 1;
    if (!cli.volumes || !cli.entries) goto done;
    int parsed = parse_options(argc, argv, &cli);
    if (parsed <= 0) {
        usage(parsed < 0 ? stdout : stderr, argv[0]);
        code = parsed < 0 ? 0 : 2;
        status = AU_OK;
        goto done;
    }
    struct sigaction on_interrupt = {.sa_handler = request_cancel};
    sigemptyset(&on_interrupt.sa_mask);
    if (sigaction(SIGINT, &on_interrupt, NULL) != 0) { status = AU_IO; goto done; }
    cli.options.cancel = cancelled;
    const char *input = argv[optind];
    const char *operand = optind + 1 < argc ? argv[optind + 1] : NULL;
    if (cli.mode == COMPRESS) {
        size_t count = (size_t)(argc - optind - 2);
        for (size_t i = 0; i < count; ++i) cli.volumes[i] = argv[optind + 2 + i];
        status = aether_unzip_create_archive(input, cli.volumes, count, operand, &cli.options);
        code = status == AU_OK ? 0 : 1;
        goto done;
    }
    status = password_context(cli.password_stdin, &context);
    if (status == AU_OK) status = open_source(input, &cli, &source);
    if (status == AU_OK) {
        switch (cli.mode) {
        case PROBE: status = probe_archive(context, source, input); break;
        case COMPRESS: break;
        case VERIFY: status = verify_archive(context, source, input, &cli); break;
        case CAT: case LIST_DIRECTORY:
            status = read_resource(context, source, input, operand, &cli);
            break;
        case AUTO:
            status = operand
                ? aether_unzip_extract_stripping_root(context, source, input, operand,
                    cli.entry_count ? cli.entries : NULL, cli.entry_count, cli.strip_root, &cli.options)
                : catalog_archive(context, source, input, &cli.options);
            break;
        }
    }
    if (fflush(stdout) != 0 && status == AU_OK) status = AU_IO;
    code = status == AU_OK ? 0 : 1;
done:
    aether_unzip_source_close(source);
    aether_unzip_context_destroy(context);
    free(cli.volumes);
    free(cli.entries);
    if (status != AU_OK) {
        const char *message = (cli.mode == CAT || cli.mode == LIST_DIRECTORY) && status == AU_EXISTS
            ? "Ambiguous resource path" : aether_unzip_error_message(status);
        fprintf(stderr, "aether-unzip: %s (status=%" PRId32 ")\n", message, status);
    }
    return code;
}
