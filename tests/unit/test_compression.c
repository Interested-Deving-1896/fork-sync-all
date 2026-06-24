// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_compression.c - Unit tests for compression name helpers
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>

#define main bdfs_cli_main_unused
#  include "../../userspace/cli/bdfs_main.c"
#undef main

static int tests_run = 0, tests_failed = 0;

#define CHECK(desc, expr) do { \
    tests_run++; \
    if (!(expr)) { \
        fprintf(stderr, "FAIL: %s\n", desc); \
        tests_failed++; \
    } else { \
        printf("PASS: %s\n", desc); \
    } \
} while (0)

static void test_name_to_enum(void)
{
    CHECK("zstd",   bdfs_compression_from_name("zstd")   == BDFS_COMPRESS_ZSTD);
    CHECK("lzma",   bdfs_compression_from_name("lzma")   == BDFS_COMPRESS_LZMA);
    CHECK("lz4",    bdfs_compression_from_name("lz4")    == BDFS_COMPRESS_LZ4);
    CHECK("brotli", bdfs_compression_from_name("brotli") == BDFS_COMPRESS_BROTLI);
    CHECK("none",   bdfs_compression_from_name("none")   == BDFS_COMPRESS_NONE);
    /* Unknown names fall back to zstd */
    CHECK("unknown defaults to zstd",
          bdfs_compression_from_name("bogus") == BDFS_COMPRESS_ZSTD);
}

static void test_enum_to_name(void)
{
    CHECK("ZSTD name",   strcmp(bdfs_compression_name(BDFS_COMPRESS_ZSTD),   "zstd")   == 0);
    CHECK("LZMA name",   strcmp(bdfs_compression_name(BDFS_COMPRESS_LZMA),   "lzma")   == 0);
    CHECK("LZ4 name",    strcmp(bdfs_compression_name(BDFS_COMPRESS_LZ4),    "lz4")    == 0);
    CHECK("BROTLI name", strcmp(bdfs_compression_name(BDFS_COMPRESS_BROTLI), "brotli") == 0);
    CHECK("NONE name",   strcmp(bdfs_compression_name(BDFS_COMPRESS_NONE),   "none")   == 0);
    CHECK("unknown enum returns non-null",
          bdfs_compression_name(0xDEAD) != NULL);
}

static void test_roundtrip(void)
{
    const char *names[] = { "zstd", "lzma", "lz4", "brotli", "none" };
    size_t i;
    for (i = 0; i < sizeof(names)/sizeof(names[0]); i++) {
        uint32_t e = bdfs_compression_from_name(names[i]);
        const char *back = bdfs_compression_name(e);
        tests_run++;
        if (strcmp(back, names[i]) == 0) {
            printf("PASS: roundtrip '%s'\n", names[i]);
        } else {
            fprintf(stderr, "FAIL: roundtrip '%s' → %u → '%s'\n",
                    names[i], e, back);
            tests_failed++;
        }
    }
}

int main(void)
{
    printf("=== Compression name helper unit tests ===\n");
    test_name_to_enum();
    test_enum_to_name();
    test_roundtrip();

    printf("\n%d/%d tests passed\n", tests_run - tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
