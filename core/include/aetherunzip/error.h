#ifndef AETHER_UNZIP_ERROR_H
#define AETHER_UNZIP_ERROR_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t au_status;
enum {
    AU_OK = 0, AU_END = 1,
    AU_INVALID = -1, AU_IO = -2, AU_NOMEM = -3, AU_UNKNOWN_FORMAT = -4,
    AU_CORRUPT = -5, AU_UNSUPPORTED = -6, AU_UNSAFE_PATH = -7,
    AU_LIMIT = -8, AU_CANCELLED = -9, AU_EXISTS = -10, AU_NOT_FOUND = -11,
    AU_ENCRYPTED = -12, AU_BAD_PASSPHRASE = -13, AU_UNSUPPORTED_ENCRYPTION = -14,
    AU_PROFILE_MISMATCH = -15
};
/* Static, NUL-terminated UTF-8 message. */
const char *aether_unzip_error_message(au_status status);

#ifdef __cplusplus
}
#endif
#endif
