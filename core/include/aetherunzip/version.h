#ifndef AETHER_UNZIP_VERSION_H
#define AETHER_UNZIP_VERSION_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define AETHER_UNZIP_ABI_VERSION 1u
/* Preview ABI. The returned version string is static UTF-8. */
uint32_t aether_unzip_abi_version(void);
const char *aether_unzip_version(void);

#ifdef __cplusplus
}
#endif
#endif
