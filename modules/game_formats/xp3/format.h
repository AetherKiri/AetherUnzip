#ifndef AETHER_UNZIP_XP3_FORMAT_H
#define AETHER_UNZIP_XP3_FORMAT_H
#include <stdint.h>

enum { XP3_HEADER = 19, XP3_SEGMENT = 28 };
#define XP3_INDEX_BUDGET (UINT64_C(32) * 1024 * 1024)
static const uint8_t xp3_magic[] = {'X', 'P', '3', 13, 10, 32, 10, 26, 0x8b, 0x67, 1};

#endif
