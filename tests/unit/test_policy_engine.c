// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_policy_engine.c - Unit tests for auto-demote policy rule matching
 *
 * Tests the rule evaluation logic (age threshold, size threshold, fnmatch
 * pattern) in isolation without kernel headers or daemon dependencies.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fnmatch.h>
#include <stdint.h>

#define BDFS_NAME_MAX 255

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

struct bdfs_policy_rule {
    char     name_pattern[BDFS_NAME_MAX + 1];
    uint32_t age_days;
    uint64_t min_size_bytes;
    int      delete_after_demote;
};

static int rule_matches(const struct bdfs_policy_rule *rule,
                        const char *subvol_name,
                        time_t last_access_time,
                        uint64_t size_bytes)
{
    time_t now = time(NULL);
    if (rule->name_pattern[0] != '\0')
        if (fnmatch(rule->name_pattern, subvol_name, 0) != 0)
            return 0;
    if (rule->age_days > 0) {
        double age = difftime(now, last_access_time) / 86400.0;
        if (age < (double)rule->age_days)
            return 0;
    }
    if (rule->min_size_bytes > 0 && size_bytes < rule->min_size_bytes)
        return 0;
    return 1;
}

static void test_pattern(void) {
    struct bdfs_policy_rule r; memset(&r,0,sizeof(r));
    strncpy(r.name_pattern,"build-*",sizeof(r.name_pattern)-1);
    time_t now=time(NULL);
    CHECK("build-* matches build-2024",  rule_matches(&r,"build-2024",now,0));
    CHECK("build-* no match release-1",  !rule_matches(&r,"release-1",now,0));
}
static void test_age(void) {
    struct bdfs_policy_rule r; memset(&r,0,sizeof(r));
    r.age_days=30;
    time_t now=time(NULL);
    CHECK("31d old triggers 30d rule",   rule_matches(&r,"x",now-31*86400,0));
    CHECK("10d old no trigger 30d rule", !rule_matches(&r,"x",now-10*86400,0));
    CHECK("age_days=0 never filters",    ({ r.age_days=0; rule_matches(&r,"x",now,0); }));
}
static void test_size(void) {
    struct bdfs_policy_rule r; memset(&r,0,sizeof(r));
    r.min_size_bytes=100ULL*1024*1024;
    time_t now=time(NULL);
    CHECK("200MiB triggers 100MiB rule", rule_matches(&r,"x",now,200ULL*1024*1024));
    CHECK("50MiB no trigger 100MiB",     !rule_matches(&r,"x",now,50ULL*1024*1024));
    CHECK("exactly 100MiB triggers",     rule_matches(&r,"x",now,100ULL*1024*1024));
}
static void test_combined(void) {
    struct bdfs_policy_rule r; memset(&r,0,sizeof(r));
    strncpy(r.name_pattern,"cache-*",sizeof(r.name_pattern)-1);
    r.age_days=7; r.min_size_bytes=10ULL*1024*1024;
    time_t now=time(NULL);
    time_t old=now-8*86400; time_t new_=now-3*86400;
    uint64_t big=20ULL*1024*1024, small=5ULL*1024*1024;
    CHECK("old+big+match triggers",      rule_matches(&r,"cache-npm",old,big));
    CHECK("new+big+match no trigger",    !rule_matches(&r,"cache-npm",new_,big));
    CHECK("old+small+match no trigger",  !rule_matches(&r,"cache-npm",old,small));
    CHECK("old+big+no-match no trigger", !rule_matches(&r,"build-npm",old,big));
}
static void test_empty_pattern(void) {
    struct bdfs_policy_rule r; memset(&r,0,sizeof(r));
    time_t now=time(NULL);
    CHECK("empty pattern matches all",   rule_matches(&r,"anything",now,0));
    CHECK("empty pattern matches empty", rule_matches(&r,"",now,0));
}
static void test_struct_fields(void) {
    struct bdfs_policy_rule r; memset(&r,0,sizeof(r));
    strncpy(r.name_pattern,"test-*",sizeof(r.name_pattern)-1);
    r.age_days=14; r.min_size_bytes=1024; r.delete_after_demote=1;
    CHECK("name_pattern ok",  strcmp(r.name_pattern,"test-*")==0);
    CHECK("age_days ok",      r.age_days==14);
    CHECK("min_size_bytes ok",r.min_size_bytes==1024);
    CHECK("delete_after ok",  r.delete_after_demote==1);
}

int main(void) {
    test_pattern(); test_age(); test_size();
    test_combined(); test_empty_pattern(); test_struct_fields();
    printf("\n%d/%d tests passed\n", tests_run-tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
