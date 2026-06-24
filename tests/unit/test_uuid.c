// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_uuid.c - Unit tests for UUID encode/decode helpers
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>

/* Pull in the helpers without the full CLI main() */
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

static void test_uuid_roundtrip(void)
{
    const uint8_t orig[16] = {
        0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0,
        0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88
    };
    char str[37];
    uint8_t decoded[16];

    bdfs_uuid_to_str(orig, str);
    CHECK("uuid_to_str produces 36-char string", strlen(str) == 36);
    CHECK("uuid_to_str has dashes at correct positions",
          str[8] == '-' && str[13] == '-' &&
          str[18] == '-' && str[23] == '-');

    int rc = bdfs_str_to_uuid(str, decoded);
    CHECK("str_to_uuid succeeds", rc == 0);
    CHECK("roundtrip preserves bytes",
          memcmp(orig, decoded, 16) == 0);
}

static void test_uuid_all_zeros(void)
{
    const uint8_t zero[16] = {0};
    char str[37];
    uint8_t decoded[16];

    bdfs_uuid_to_str(zero, str);
    CHECK("all-zero uuid string",
          strcmp(str, "00000000-0000-0000-0000-000000000000") == 0);

    bdfs_str_to_uuid(str, decoded);
    CHECK("all-zero roundtrip", memcmp(zero, decoded, 16) == 0);
}

static void test_uuid_all_ff(void)
{
    const uint8_t ff[16] = {
        0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
        0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff
    };
    char str[37];
    uint8_t decoded[16];

    bdfs_uuid_to_str(ff, str);
    CHECK("all-ff uuid string",
          strcmp(str, "ffffffff-ffff-ffff-ffff-ffffffffffff") == 0);

    bdfs_str_to_uuid(str, decoded);
    CHECK("all-ff roundtrip", memcmp(ff, decoded, 16) == 0);
}

static void test_uuid_invalid_input(void)
{
    uint8_t out[16];
    CHECK("invalid uuid string rejected",
          bdfs_str_to_uuid("not-a-uuid", out) < 0);
    CHECK("short uuid string rejected",
          bdfs_str_to_uuid("12345678-1234-1234-1234-12345678", out) < 0);
    CHECK("empty string rejected",
          bdfs_str_to_uuid("", out) < 0);
}

int main(void)
{
    printf("=== UUID helper unit tests ===\n");
    test_uuid_roundtrip();
    test_uuid_all_zeros();
    test_uuid_all_ff();
    test_uuid_invalid_input();

    printf("\n%d/%d tests passed\n", tests_run - tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
