// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_socket_dispatch.c - Unit tests for the daemon socket command dispatch
 *
 * Tests the JSON request parsing and response formatting logic in
 * bdfs_socket.c without requiring a real Unix socket or daemon.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define BDFS_UNIT_TEST 1

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

/* ── JSON helpers (replicated from bdfs_socket.c logic) ─────────────────── */

/*
 * Minimal JSON field extractor used by the socket dispatch.
 * Returns a pointer to the value string (null-terminated in a static buffer)
 * or NULL if the key is not found.
 */
static const char *json_get_str(const char *json, const char *key,
                                char *out, size_t outsz)
{
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return NULL;
    p += strlen(needle);
    while (*p == ' ' || *p == ':' || *p == ' ') p++;
    if (*p == '"') {
        p++;
        size_t i = 0;
        while (*p && *p != '"' && i + 1 < outsz)
            out[i++] = *p++;
        out[i] = '\0';
        return out;
    }
    return NULL;
}

static int json_get_int(const char *json, const char *key, int *out)
{
    char buf[64];
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return 0;
    p += strlen(needle);
    while (*p == ' ' || *p == ':') p++;
    if (*p == '-' || (*p >= '0' && *p <= '9')) {
        snprintf(buf, sizeof(buf), "%s", p);
        *out = atoi(buf);
        return 1;
    }
    return 0;
}

/* ── Command name parsing ────────────────────────────────────────────────── */

static void test_parse_command_field(void)
{
    char val[64];

    CHECK("parse 'status' command",
          json_get_str("{\"cmd\":\"status\"}", "cmd", val, sizeof(val)) &&
          strcmp(val, "status") == 0);

    CHECK("parse 'policy-list' command",
          json_get_str("{\"cmd\":\"policy-list\"}", "cmd", val, sizeof(val)) &&
          strcmp(val, "policy-list") == 0);

    CHECK("parse 'policy-scan' command",
          json_get_str("{\"cmd\":\"policy-scan\"}", "cmd", val, sizeof(val)) &&
          strcmp(val, "policy-scan") == 0);

    CHECK("missing cmd field returns NULL",
          json_get_str("{\"other\":\"value\"}", "cmd", val, sizeof(val)) == NULL);

    CHECK("empty JSON returns NULL",
          json_get_str("{}", "cmd", val, sizeof(val)) == NULL);
}

/* ── Policy-add argument parsing ─────────────────────────────────────────── */

static void test_parse_policy_add_args(void)
{
    const char *req =
        "{\"cmd\":\"policy-add\","
        "\"partition_uuid\":\"aabbccdd-1122-3344-5566-778899aabbcc\","
        "\"pattern\":\"build-*\","
        "\"age_days\":30,"
        "\"min_size_mb\":100,"
        "\"delete_after\":1}";

    char uuid[64], pattern[64];
    int age = 0, size_mb = 0, del = 0;

    CHECK("parse partition_uuid",
          json_get_str(req, "partition_uuid", uuid, sizeof(uuid)) &&
          strcmp(uuid, "aabbccdd-1122-3344-5566-778899aabbcc") == 0);

    CHECK("parse pattern",
          json_get_str(req, "pattern", pattern, sizeof(pattern)) &&
          strcmp(pattern, "build-*") == 0);

    CHECK("parse age_days",
          json_get_int(req, "age_days", &age) && age == 30);

    CHECK("parse min_size_mb",
          json_get_int(req, "min_size_mb", &size_mb) && size_mb == 100);

    CHECK("parse delete_after",
          json_get_int(req, "delete_after", &del) && del == 1);
}

/* ── Response formatting ─────────────────────────────────────────────────── */

static void test_response_format(void)
{
    char resp[512];

    /* Success response */
    snprintf(resp, sizeof(resp),
             "{\"status\":0,\"data\":{\"workers\":%d,\"queue_depth\":%d,"
             "\"active_mounts\":%d,\"policy_demotes\":%llu,"
             "\"policy_last_scan\":%lld}}\n",
             4, 0, 2, (unsigned long long)7, (long long)1700000000LL);

    char val[64];
    int ival = -1;

    CHECK("response contains status=0",
          json_get_int(resp, "status", &ival) && ival == 0);

    CHECK("response contains workers field",
          json_get_int(resp, "workers", &ival) && ival == 4);

    CHECK("response contains active_mounts field",
          json_get_int(resp, "active_mounts", &ival) && ival == 2);

    /* Error response */
    snprintf(resp, sizeof(resp),
             "{\"status\":-1,\"error\":\"unknown command\"}\n");

    CHECK("error response status=-1",
          json_get_int(resp, "status", &ival) && ival == -1);

    CHECK("error response has error field",
          json_get_str(resp, "error", val, sizeof(val)) &&
          strcmp(val, "unknown command") == 0);
}

/* ── Unknown command handling ────────────────────────────────────────────── */

static void test_unknown_command(void)
{
    /* Simulate the dispatch: any cmd not in the known set → error */
    const char *known[] = {
        "status", "policy-add", "policy-remove", "policy-list",
        "policy-scan", NULL
    };

    const char *test_cmds[] = {
        "status",       /* known */
        "policy-add",   /* known */
        "reboot",       /* unknown */
        "rm -rf /",     /* unknown */
        "",             /* unknown */
        NULL
    };

    int expected[] = { 1, 1, 0, 0, 0 };

    for (int i = 0; test_cmds[i]; i++) {
        int found = 0;
        for (int j = 0; known[j]; j++) {
            if (strcmp(test_cmds[i], known[j]) == 0) {
                found = 1;
                break;
            }
        }
        char desc[128];
        snprintf(desc, sizeof(desc), "cmd '%s' known=%d",
                 test_cmds[i], expected[i]);
        CHECK(desc, found == expected[i]);
    }
}

int main(void)
{
    test_parse_command_field();
    test_parse_policy_add_args();
    test_response_format();
    test_unknown_command();

    printf("\n%d/%d tests passed\n", tests_run - tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
