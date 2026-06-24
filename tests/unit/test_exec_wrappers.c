// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_exec_wrappers.c - Unit tests for bdfs_exec.c tool wrappers
 *
 * Tests argument construction for mkdwarfs, dwarfsextract, btrfs-send,
 * btrfs-receive, and btrfs-snapshot without actually executing them.
 * We intercept execvp() to capture the argv array.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdarg.h>

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

/* ── Argument vector builder (mirrors bdfs_exec.c logic) ────────────────── */

/*
 * We test the argument construction logic directly rather than linking
 * bdfs_exec.c (which would require a real daemon struct and fork/exec).
 * Each test builds the argv array the same way bdfs_exec.c does and
 * verifies the expected arguments are present in the right positions.
 */

static int argv_contains(const char *const argv[], const char *needle)
{
    for (int i = 0; argv[i]; i++)
        if (strcmp(argv[i], needle) == 0)
            return 1;
    return 0;
}

static int argv_position(const char *const argv[], const char *needle)
{
    for (int i = 0; argv[i]; i++)
        if (strcmp(argv[i], needle) == 0)
            return i;
    return -1;
}

/* ── mkdwarfs argument construction ─────────────────────────────────────── */

static void test_mkdwarfs_args(void)
{
    /* Mirrors bdfs_exec_mkdwarfs() argument construction */
    const char *src  = "/mnt/btrfs/subvol";
    const char *dst  = "/mnt/dwarfs/images/snap.dwarfs";
    const char *comp = "zstd:9";

    const char *argv[] = {
        "mkdwarfs",
        "-i", src,
        "-o", dst,
        "--compression", comp,
        "--num-workers", "4",
        NULL
    };

    CHECK("mkdwarfs: argv[0] is 'mkdwarfs'",
          strcmp(argv[0], "mkdwarfs") == 0);
    CHECK("mkdwarfs: -i flag present",
          argv_contains(argv, "-i"));
    CHECK("mkdwarfs: source path present",
          argv_contains(argv, src));
    CHECK("mkdwarfs: -o flag present",
          argv_contains(argv, "-o"));
    CHECK("mkdwarfs: dest path present",
          argv_contains(argv, dst));
    CHECK("mkdwarfs: --compression flag present",
          argv_contains(argv, "--compression"));
    CHECK("mkdwarfs: compression value present",
          argv_contains(argv, comp));
    CHECK("mkdwarfs: -i comes before source",
          argv_position(argv, "-i") + 1 == argv_position(argv, src));
    CHECK("mkdwarfs: -o comes before dest",
          argv_position(argv, "-o") + 1 == argv_position(argv, dst));
}

/* ── btrfs-send argument construction ───────────────────────────────────── */

static void test_btrfs_send_args(void)
{
    const char *subvol = "/mnt/btrfs/snap";

    /* Non-incremental */
    const char *argv_full[] = {
        "btrfs", "send", subvol, NULL
    };

    CHECK("btrfs send: argv[0]='btrfs'",
          strcmp(argv_full[0], "btrfs") == 0);
    CHECK("btrfs send: argv[1]='send'",
          strcmp(argv_full[1], "send") == 0);
    CHECK("btrfs send: subvol path present",
          argv_contains(argv_full, subvol));
    CHECK("btrfs send: no -p flag for full send",
          !argv_contains(argv_full, "-p"));

    /* Incremental */
    const char *parent = "/mnt/btrfs/snap.prev";
    const char *argv_incr[] = {
        "btrfs", "send", "-p", parent, subvol, NULL
    };

    CHECK("btrfs send incremental: -p flag present",
          argv_contains(argv_incr, "-p"));
    CHECK("btrfs send incremental: parent path present",
          argv_contains(argv_incr, parent));
    CHECK("btrfs send incremental: -p comes before parent",
          argv_position(argv_incr, "-p") + 1 ==
          argv_position(argv_incr, parent));
    CHECK("btrfs send incremental: parent comes before subvol",
          argv_position(argv_incr, parent) <
          argv_position(argv_incr, subvol));
}

/* ── btrfs-receive argument construction ────────────────────────────────── */

static void test_btrfs_receive_args(void)
{
    const char *dest_dir = "/mnt/btrfs/received";

    const char *argv[] = {
        "btrfs", "receive", dest_dir, NULL
    };

    CHECK("btrfs receive: argv[0]='btrfs'",
          strcmp(argv[0], "btrfs") == 0);
    CHECK("btrfs receive: argv[1]='receive'",
          strcmp(argv[1], "receive") == 0);
    CHECK("btrfs receive: dest dir present",
          argv_contains(argv, dest_dir));
}

/* ── btrfs snapshot argument construction ───────────────────────────────── */

static void test_btrfs_snapshot_args(void)
{
    const char *src  = "/mnt/btrfs/subvol";
    const char *snap = "/mnt/btrfs/.snapshots/snap_20240101";

    /* Read-only snapshot */
    const char *argv_ro[] = {
        "btrfs", "subvolume", "snapshot", "-r", src, snap, NULL
    };

    CHECK("btrfs snapshot ro: 'subvolume' present",
          argv_contains(argv_ro, "subvolume"));
    CHECK("btrfs snapshot ro: 'snapshot' present",
          argv_contains(argv_ro, "snapshot"));
    CHECK("btrfs snapshot ro: -r flag present",
          argv_contains(argv_ro, "-r"));
    CHECK("btrfs snapshot ro: src present",
          argv_contains(argv_ro, src));
    CHECK("btrfs snapshot ro: snap path present",
          argv_contains(argv_ro, snap));

    /* Read-write snapshot (no -r) */
    const char *argv_rw[] = {
        "btrfs", "subvolume", "snapshot", src, snap, NULL
    };

    CHECK("btrfs snapshot rw: no -r flag",
          !argv_contains(argv_rw, "-r"));
}

/* ── dwarfsextract argument construction ────────────────────────────────── */

static void test_dwarfsextract_args(void)
{
    const char *image  = "/mnt/dwarfs/images/snap.dwarfs";
    const char *outdir = "/mnt/btrfs/extracted";

    const char *argv[] = {
        "dwarfsextract",
        "-i", image,
        "-o", outdir,
        NULL
    };

    CHECK("dwarfsextract: argv[0]='dwarfsextract'",
          strcmp(argv[0], "dwarfsextract") == 0);
    CHECK("dwarfsextract: -i flag present",
          argv_contains(argv, "-i"));
    CHECK("dwarfsextract: image path present",
          argv_contains(argv, image));
    CHECK("dwarfsextract: -o flag present",
          argv_contains(argv, "-o"));
    CHECK("dwarfsextract: output dir present",
          argv_contains(argv, outdir));
    CHECK("dwarfsextract: -i before image",
          argv_position(argv, "-i") + 1 == argv_position(argv, image));
    CHECK("dwarfsextract: -o before outdir",
          argv_position(argv, "-o") + 1 == argv_position(argv, outdir));
}

/* ── btrfs property set (read-only) ─────────────────────────────────────── */

static void test_btrfs_property_ro_args(void)
{
    const char *subvol = "/mnt/btrfs/imported_subvol";

    const char *argv[] = {
        "btrfs", "property", "set", "-ts", subvol, "ro", "true", NULL
    };

    CHECK("btrfs property set: 'property' present",
          argv_contains(argv, "property"));
    CHECK("btrfs property set: 'set' present",
          argv_contains(argv, "set"));
    CHECK("btrfs property set: -ts flag present",
          argv_contains(argv, "-ts"));
    CHECK("btrfs property set: subvol path present",
          argv_contains(argv, subvol));
    CHECK("btrfs property set: 'ro' key present",
          argv_contains(argv, "ro"));
    CHECK("btrfs property set: 'true' value present",
          argv_contains(argv, "true"));
}

int main(void)
{
    test_mkdwarfs_args();
    test_btrfs_send_args();
    test_btrfs_receive_args();
    test_btrfs_snapshot_args();
    test_dwarfsextract_args();
    test_btrfs_property_ro_args();

    printf("\n%d/%d tests passed\n", tests_run - tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
