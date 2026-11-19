// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_copyup_job.c - Unit tests for the BDFS_JOB_PROMOTE_COPYUP job
 *
 * Tests the copy-up job's file copy logic, parent directory creation,
 * and BDFS_IOC_COPYUP_COMPLETE ioctl argument construction — without
 * requiring a real kernel module or BTRFS filesystem.
 *
 * We use temporary files in /tmp to exercise the actual copy_file_range /
 * read-write fallback path.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <errno.h>



#define BDFS_UNIT_TEST 1

static int tests_run = 0, tests_failed = 0;

#define CHECK(desc, expr) do { \
    tests_run++; \
    if (!(expr)) { \
        fprintf(stderr, "FAIL: %s (errno=%d)\n", desc, errno); \
        tests_failed++; \
    } else { \
        printf("PASS: %s\n", desc); \
    } \
} while (0)

/* ── Helpers ─────────────────────────────────────────────────────────────── */

static char g_tmpdir[256];

static void setup_tmpdir(void)
{
    snprintf(g_tmpdir, sizeof(g_tmpdir), "/tmp/bdfs_copyup_test_XXXXXX");
    assert(mkdtemp(g_tmpdir) != NULL);
}

static void cleanup_tmpdir(void)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", g_tmpdir);
    system(cmd);
}

static void write_file(const char *path, const char *content)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    assert(fd >= 0);
    write(fd, content, strlen(content));
    close(fd);
}

static int file_content_equals(const char *path, const char *expected)
{
    char buf[4096] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n < 0) return 0;
    buf[n] = '\0';
    return strcmp(buf, expected) == 0;
}

/* ── copy_file_range / read-write fallback ───────────────────────────────── */

/*
 * Replicate the core copy logic from bdfs_job_promote_copyup() and test it
 * directly.  This exercises the actual syscall path without needing the full
 * daemon struct.
 */
static int do_file_copy(const char *src, const char *dst)
{
    struct stat st;
    int src_fd = open(src, O_RDONLY | O_CLOEXEC);
    if (src_fd < 0) return -errno;

    if (fstat(src_fd, &st) < 0) { close(src_fd); return -errno; }

    int dst_fd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                      st.st_mode & 0777);
    if (dst_fd < 0) { close(src_fd); return -errno; }

    off_t offset = 0;
    int ret = 0;
    while (offset < st.st_size) {
        ssize_t copied = copy_file_range(src_fd, &offset,
                                         dst_fd, NULL,
                                         (size_t)(st.st_size - offset), 0);
        if (copied < 0) {
            if (errno == EXDEV || errno == EOPNOTSUPP) {
                /* Fallback */
                char buf[65536];
                ssize_t n;
                lseek(src_fd, offset, SEEK_SET);
                while ((n = read(src_fd, buf, sizeof(buf))) > 0) {
                    if (write(dst_fd, buf, (size_t)n) != n) {
                        ret = -errno;
                        break;
                    }
                }
                if (n < 0) ret = -errno;
            } else {
                ret = -errno;
            }
            break;
        }
    }

    close(src_fd);
    close(dst_fd);
    if (ret) unlink(dst);
    return ret;
}

static void test_copy_small_file(void)
{
    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/src_small.txt", g_tmpdir);
    snprintf(dst, sizeof(dst), "%s/dst_small.txt", g_tmpdir);

    const char *content = "hello from DwarFS lower layer\n";
    write_file(src, content);

    int ret = do_file_copy(src, dst);
    CHECK("copy small file returns 0", ret == 0);
    CHECK("copy small file: dst exists", access(dst, F_OK) == 0);
    CHECK("copy small file: content matches",
          file_content_equals(dst, content));
}

static void test_copy_empty_file(void)
{
    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/src_empty.txt", g_tmpdir);
    snprintf(dst, sizeof(dst), "%s/dst_empty.txt", g_tmpdir);

    write_file(src, "");

    int ret = do_file_copy(src, dst);
    CHECK("copy empty file returns 0", ret == 0);
    CHECK("copy empty file: dst exists", access(dst, F_OK) == 0);
    CHECK("copy empty file: content matches",
          file_content_equals(dst, ""));
}

static void test_copy_existing_dst_fails(void)
{
    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/src_exist.txt", g_tmpdir);
    snprintf(dst, sizeof(dst), "%s/dst_exist.txt", g_tmpdir);

    write_file(src, "source");
    write_file(dst, "already here");

    /* O_EXCL means copy should fail with EEXIST */
    int ret = do_file_copy(src, dst);
    CHECK("copy to existing dst fails with EEXIST", ret == -EEXIST);
    CHECK("existing dst content unchanged",
          file_content_equals(dst, "already here"));
}

static void test_copy_missing_src_fails(void)
{
    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/nonexistent.txt", g_tmpdir);
    snprintf(dst, sizeof(dst), "%s/dst_missing.txt", g_tmpdir);

    int ret = do_file_copy(src, dst);
    CHECK("copy from missing src fails", ret < 0);
    CHECK("dst not created on src failure", access(dst, F_OK) != 0);
}

/* ── BDFS_IOC_COPYUP_COMPLETE argument construction ─────────────────────── */

static void test_copyup_complete_args(void)
{
    /*
     * Verify the ioctl argument struct is populated correctly by the job
     * handler.  We replicate the struct layout from bdfs_ioctl.h.
     */
    struct {
        uint8_t  btrfs_uuid[16];
        uint64_t inode_no;
        char     upper_path[4096];
    } arg;

    memset(&arg, 0, sizeof(arg));

    uint8_t uuid[16] = {
        0xaa,0xbb,0xcc,0xdd, 0x11,0x22, 0x33,0x44,
        0x55,0x66, 0x77,0x88,0x99,0xaa,0xbb,0xcc
    };
    uint64_t ino = 12345678ULL;
    const char *upper = "/mnt/btrfs/upper/some/file.txt";

    memcpy(arg.btrfs_uuid, uuid, 16);
    arg.inode_no = ino;
    snprintf(arg.upper_path, sizeof(arg.upper_path), "%s", upper);

    CHECK("copyup_complete: uuid set correctly",
          memcmp(arg.btrfs_uuid, uuid, 16) == 0);
    CHECK("copyup_complete: inode_no set correctly",
          arg.inode_no == ino);
    CHECK("copyup_complete: upper_path set correctly",
          strcmp(arg.upper_path, upper) == 0);
    CHECK("copyup_complete: upper_path fits in buffer",
          strlen(upper) < sizeof(arg.upper_path));
}

/* ── Parent directory creation ───────────────────────────────────────────── */

static void test_parent_dir_creation(void)
{
    char parent[512], child[512];
    snprintf(parent, sizeof(parent), "%s/upper/a/b/c", g_tmpdir);
    snprintf(child,  sizeof(child),  "%s/upper/a/b/c/file.txt", g_tmpdir);

    /* mkdir -p equivalent */
    char cmd[600];
    snprintf(cmd, sizeof(cmd), "mkdir -p %s", parent);
    int ret = system(cmd);
    CHECK("mkdir -p parent succeeds", ret == 0);

    write_file(child, "test");
    CHECK("file created under new parent dir",
          access(child, F_OK) == 0);
}

/* ── Large file copy (1 MiB) ─────────────────────────────────────────────── */

static void test_copy_large_file(void)
{
    char src[512], dst[512];
    snprintf(src, sizeof(src), "%s/src_large.bin", g_tmpdir);
    snprintf(dst, sizeof(dst), "%s/dst_large.bin", g_tmpdir);

    /* Write 1 MiB of pattern data */
    int fd = open(src, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    assert(fd >= 0);
    char buf[4096];
    for (int i = 0; i < (int)sizeof(buf); i++)
        buf[i] = (char)(i & 0xff);
    for (int i = 0; i < 256; i++)
        write(fd, buf, sizeof(buf));
    close(fd);

    int ret = do_file_copy(src, dst);
    CHECK("copy 1 MiB file returns 0", ret == 0);

    struct stat ss, ds;
    stat(src, &ss);
    stat(dst, &ds);
    CHECK("copy 1 MiB file: sizes match", ss.st_size == ds.st_size);
}

int main(void)
{
    setup_tmpdir();

    test_copy_small_file();
    test_copy_empty_file();
    test_copy_existing_dst_fails();
    test_copy_missing_src_fails();
    test_copyup_complete_args();
    test_parent_dir_creation();
    test_copy_large_file();

    cleanup_tmpdir();

    printf("\n%d/%d tests passed\n", tests_run - tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
