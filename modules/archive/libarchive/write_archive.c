#include "internal.h"
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <locale.h>
#include <stdlib.h>

typedef struct {
    struct archive *archive;
    struct archive_entry *entry;
    locale_t utf8, original;
    int finished;
} writer;

static int configure_writer(struct archive *archive, au_write_format format) {
    if (format == AU_WRITE_ZIP) {
        int result = archive_write_set_format_zip(archive);
        return result == ARCHIVE_OK ? archive_write_zip_set_compression_deflate(archive) : result;
    }
    int result = archive_write_set_format_pax_restricted(archive);
    if (result != ARCHIVE_OK) return result;
    if (format == AU_WRITE_TAR_GZIP) return archive_write_add_filter_gzip(archive);
    if (format == AU_WRITE_TAR_ZSTD) return archive_write_add_filter_zstd(archive);
    return ARCHIVE_OK;
}

static au_status writer_error(const writer *state) {
    int error = archive_errno(state->archive);
    return error == ENOMEM ? AU_NOMEM : au_output_error(error);
}

static au_status begin(void *opaque, const char *name, const struct stat *info) {
    writer *state = opaque;
    int directory = S_ISDIR(info->st_mode);
    archive_entry_clear(state->entry);
    archive_entry_set_pathname(state->entry, name);
    archive_entry_set_filetype(state->entry, directory ? AE_IFDIR : AE_IFREG);
    archive_entry_set_perm(state->entry, directory ? 0755 : 0644);
    archive_entry_set_mtime(state->entry, info->st_mtime, 0);
    archive_entry_set_size(state->entry, directory ? 0 : info->st_size);
    return archive_write_header(state->archive, state->entry) == ARCHIVE_OK ? AU_OK : writer_error(state);
}

static au_status write_bytes(void *opaque, const void *data, size_t count) {
    writer *state = opaque;
    return archive_write_data(state->archive, data, count) == (la_ssize_t)count ? AU_OK : writer_error(state);
}

static au_status end(void *opaque) {
    writer *state = opaque;
    return archive_write_finish_entry(state->archive) == ARCHIVE_OK ? AU_OK : writer_error(state);
}

static au_status finish(void *opaque) {
    writer *state = opaque;
    if (archive_write_close(state->archive) != ARCHIVE_OK) return writer_error(state);
    state->finished = 1;
    return AU_OK;
}

static void destroy(void *opaque) {
    writer *state = opaque;
    if (state->archive) {
        if (!state->finished) archive_write_fail(state->archive);
        archive_write_free(state->archive);
    }
    archive_entry_free(state->entry);
    if (state->original) uselocale(state->original);
    if (state->utf8) freelocale(state->utf8);
    free(state);
}

au_status au_libarchive_encoder_open(int fd, au_write_format format, au_encoder *out) {
    writer *state = calloc(1, sizeof(*state));
    if (!state) return AU_NOMEM;
    state->utf8 = newlocale(LC_CTYPE_MASK, "C.UTF-8", NULL);
    if (!state->utf8) state->utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", NULL);
    au_status status = AU_OK;
    if (!state->utf8) status = AU_UNSUPPORTED;
    else if (!(state->original = uselocale(state->utf8))) status = AU_IO;
    else {
        state->archive = archive_write_new();
        state->entry = archive_entry_new();
        if (!state->archive || !state->entry) status = AU_NOMEM;
        else if (configure_writer(state->archive, format) != ARCHIVE_OK ||
                 archive_write_set_bytes_per_block(state->archive, 0) != ARCHIVE_OK ||
                 archive_write_open_fd(state->archive, fd) != ARCHIVE_OK) status = writer_error(state);
    }
    if (status != AU_OK) {
        destroy(state);
        return status;
    }
    *out = (au_encoder){state, begin, write_bytes, end, finish, destroy};
    return AU_OK;
}
