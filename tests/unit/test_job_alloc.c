// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * test_job_alloc.c - Unit tests for daemon job allocation and queue
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include <pthread.h>

/* Stub out the parts of bdfs_daemon.c that need real system resources */
#define BDFS_UNIT_TEST 1

/* Provide stub implementations for functions that open real fds */
static int stub_netlink_init_called = 0;
static int stub_socket_init_called  = 0;

/* Include only the job alloc/free/enqueue logic by redefining main.
 * When building via cmake (BDFS_CMAKE_BUILD), all source files are compiled
 * as separate TUs and linked together — include only the header for type
 * and function declarations. For standalone gcc builds, include bdfs_daemon.c
 * directly so the macro stubs below take effect. */
#define main bdfs_daemon_main_unused
#define bdfs_netlink_init(d) (stub_netlink_init_called++, (d)->nl_fd = -1, 0)
#define bdfs_socket_init(d)  (stub_socket_init_called++,  (d)->sock_fd = -1, 0)
#ifdef BDFS_CMAKE_BUILD
#  include "../../userspace/daemon/bdfs_daemon.h"
#else
#  include "../../userspace/daemon/bdfs_daemon.c"
#endif
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

static void test_job_alloc_free(void)
{
    struct bdfs_job *job;

    job = bdfs_job_alloc(BDFS_JOB_EXPORT_TO_DWARFS);
    CHECK("alloc returns non-NULL", job != NULL);
    CHECK("type set correctly", job->type == BDFS_JOB_EXPORT_TO_DWARFS);
    CHECK("object_id zeroed", job->object_id == 0);
    bdfs_job_free(job);

    job = bdfs_job_alloc(BDFS_JOB_MOUNT_DWARFS);
    CHECK("alloc MOUNT_DWARFS", job != NULL && job->type == BDFS_JOB_MOUNT_DWARFS);
    bdfs_job_free(job);

    job = bdfs_job_alloc(BDFS_JOB_SNAPSHOT_CONTAINER);
    CHECK("alloc SNAPSHOT_CONTAINER",
          job != NULL && job->type == BDFS_JOB_SNAPSHOT_CONTAINER);
    bdfs_job_free(job);
}

static void test_job_queue_order(void)
{
    struct bdfs_daemon d;
    memset(&d, 0, sizeof(d));
    TAILQ_INIT(&d.job_queue);
    pthread_mutex_init(&d.queue_lock, NULL);
    pthread_cond_init(&d.queue_cond, NULL);

    /* Enqueue three jobs */
    struct bdfs_job *j1 = bdfs_job_alloc(BDFS_JOB_EXPORT_TO_DWARFS);
    struct bdfs_job *j2 = bdfs_job_alloc(BDFS_JOB_IMPORT_FROM_DWARFS);
    struct bdfs_job *j3 = bdfs_job_alloc(BDFS_JOB_MOUNT_DWARFS);
    j1->object_id = 1;
    j2->object_id = 2;
    j3->object_id = 3;

    bdfs_daemon_enqueue(&d, j1);
    bdfs_daemon_enqueue(&d, j2);
    bdfs_daemon_enqueue(&d, j3);

    /* Dequeue and verify FIFO order */
    struct bdfs_job *got;

    got = TAILQ_FIRST(&d.job_queue);
    TAILQ_REMOVE(&d.job_queue, got, entry);
    CHECK("first dequeued is j1", got->object_id == 1);
    bdfs_job_free(got);

    got = TAILQ_FIRST(&d.job_queue);
    TAILQ_REMOVE(&d.job_queue, got, entry);
    CHECK("second dequeued is j2", got->object_id == 2);
    bdfs_job_free(got);

    got = TAILQ_FIRST(&d.job_queue);
    TAILQ_REMOVE(&d.job_queue, got, entry);
    CHECK("third dequeued is j3", got->object_id == 3);
    bdfs_job_free(got);

    CHECK("queue empty after dequeue", TAILQ_EMPTY(&d.job_queue));

    pthread_mutex_destroy(&d.queue_lock);
    pthread_cond_destroy(&d.queue_cond);
}

static void test_job_fields(void)
{
    struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_EXPORT_TO_DWARFS);

    /* Set export fields */
    job->export_to_dwarfs.subvol_id    = 42;
    job->export_to_dwarfs.compression  = BDFS_COMPRESS_ZSTD;
    job->export_to_dwarfs.worker_threads = 8;
    strncpy(job->export_to_dwarfs.image_name, "test_image",
            sizeof(job->export_to_dwarfs.image_name) - 1);

    CHECK("subvol_id set",    job->export_to_dwarfs.subvol_id == 42);
    CHECK("compression set",  job->export_to_dwarfs.compression == BDFS_COMPRESS_ZSTD);
    CHECK("workers set",      job->export_to_dwarfs.worker_threads == 8);
    CHECK("image_name set",
          strcmp(job->export_to_dwarfs.image_name, "test_image") == 0);

    bdfs_job_free(job);
}

static void test_job_uuid_copy(void)
{
    struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_STORE_IMAGE);
    const uint8_t uuid[16] = {
        0xde,0xad,0xbe,0xef,0xca,0xfe,0xba,0xbe,
        0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef
    };
    memcpy(job->partition_uuid, uuid, 16);
    CHECK("partition_uuid copied",
          memcmp(job->partition_uuid, uuid, 16) == 0);
    bdfs_job_free(job);
}

int main(void)
{
    printf("=== Daemon job allocation unit tests ===\n");
    test_job_alloc_free();
    test_job_queue_order();
    test_job_fields();
    test_job_uuid_copy();

    printf("\n%d/%d tests passed\n", tests_run - tests_failed, tests_run);
    return tests_failed ? 1 : 0;
}
