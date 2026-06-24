# SPDX-License-Identifier: GPL-2.0-or-later
cmake_minimum_required(VERSION 3.16)

# Unit tests for userspace components.
# These do not require root or real block devices.

enable_testing()

include_directories(
    ${CMAKE_SOURCE_DIR}/../../include
    ${CMAKE_SOURCE_DIR}/../../include/uapi
    ${CMAKE_SOURCE_DIR}/../../userspace/cli
    ${CMAKE_SOURCE_DIR}/../../userspace/daemon
)

# ── test_uuid ────────────────────────────────────────────────────────────────
add_executable(test_uuid test_uuid.c)
target_compile_definitions(test_uuid PRIVATE BDFS_UNIT_TEST)
target_link_options(test_uuid PRIVATE -Wl,--unresolved-symbols=ignore-in-object-files)
add_test(NAME uuid COMMAND test_uuid)

# ── test_compression_names ───────────────────────────────────────────────────
add_executable(test_compression test_compression.c)
target_compile_definitions(test_compression PRIVATE BDFS_UNIT_TEST)
target_link_options(test_compression PRIVATE -Wl,--unresolved-symbols=ignore-in-object-files)
add_test(NAME compression COMMAND test_compression)

# ── test_job_alloc ───────────────────────────────────────────────────────────
add_executable(test_job_alloc test_job_alloc.c
    ../../userspace/daemon/bdfs_daemon.c
    ../../userspace/daemon/bdfs_jobs.c
    ../../userspace/daemon/bdfs_exec.c
    ../../userspace/daemon/bdfs_netlink.c
    ../../userspace/daemon/bdfs_socket.c
    ../../userspace/daemon/bdfs_policy.c)
target_compile_definitions(test_job_alloc PRIVATE BDFS_UNIT_TEST BDFS_CMAKE_BUILD)
target_link_libraries(test_job_alloc PRIVATE pthread)
add_test(NAME job_alloc COMMAND test_job_alloc)

# ── test_policy_engine ───────────────────────────────────────────────────────
# Tests rule matching logic (age, size, fnmatch) without a real filesystem.
add_executable(test_policy_engine test_policy_engine.c)
target_compile_definitions(test_policy_engine PRIVATE BDFS_UNIT_TEST)
add_test(NAME policy_engine COMMAND test_policy_engine)

# ── test_socket_dispatch ─────────────────────────────────────────────────────
# Tests JSON request parsing and response formatting.
add_executable(test_socket_dispatch test_socket_dispatch.c)
target_compile_definitions(test_socket_dispatch PRIVATE BDFS_UNIT_TEST)
add_test(NAME socket_dispatch COMMAND test_socket_dispatch)

# ── test_exec_wrappers ───────────────────────────────────────────────────────
# Tests argv construction for mkdwarfs, btrfs-send, btrfs-receive, etc.
add_executable(test_exec_wrappers test_exec_wrappers.c)
target_compile_definitions(test_exec_wrappers PRIVATE BDFS_UNIT_TEST)
add_test(NAME exec_wrappers COMMAND test_exec_wrappers)

# ── test_copyup_job ──────────────────────────────────────────────────────────
# Tests copy-up file copy logic and ioctl argument construction.
add_executable(test_copyup_job test_copyup_job.c)
target_compile_definitions(test_copyup_job PRIVATE BDFS_UNIT_TEST)
add_test(NAME copyup_job COMMAND test_copyup_job)
