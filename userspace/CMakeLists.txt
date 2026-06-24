# SPDX-License-Identifier: GPL-2.0-or-later
cmake_minimum_required(VERSION 3.16)
project(btrfs_dwarfs_userspace
    VERSION 1.0.0
    DESCRIPTION "BTRFS+DwarFS hybrid filesystem userspace tools"
    LANGUAGES C
)

# ── Build options ────────────────────────────────────────────────────────────
option(BUILD_DAEMON           "Build the bdfs_daemon"                    ON)
option(BUILD_CLI              "Build the bdfs CLI"                       ON)
option(BUILD_TESTS            "Build unit tests"                         OFF)
option(ENABLE_ASAN            "Enable AddressSanitizer"                  OFF)
option(BUILD_GITLAB_ENHANCED  "Build and install gitlab-enhanced + bdfs-pin-helper from integrations/gitlab-enhanced submodule" OFF)

# ── Compiler flags ───────────────────────────────────────────────────────────
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_compile_options(
    -Wall -Wextra -Wpedantic
    -Wformat=2 -Wformat-security
    -Wno-unused-parameter
    -D_GNU_SOURCE
    -D_FILE_OFFSET_BITS=64
)

if(ENABLE_ASAN)
    add_compile_options(-fsanitize=address,undefined)
    add_link_options(-fsanitize=address,undefined)
endif()

# ── Kernel header feature detection ─────────────────────────────────────────
# btrfs_qgroup_info_item.exclusive was renamed to .excl in kernel 5.15+.
# Detect which name is present so bdfs_policy.c compiles against both.
include(CheckStructHasMember)
check_struct_has_member(
    "struct btrfs_qgroup_info_item" excl
    "linux/btrfs_tree.h"
    BDFS_BTRFS_QGROUP_HAS_EXCL
    LANGUAGE C
)
if(BDFS_BTRFS_QGROUP_HAS_EXCL)
    add_compile_definitions(BDFS_BTRFS_QGROUP_HAS_EXCL)
    message(STATUS "btrfs_qgroup_info_item: using field 'excl' (kernel >= 5.15)")
else()
    message(STATUS "btrfs_qgroup_info_item: using field 'exclusive' (kernel < 5.15)")
endif()

# ── Include paths ────────────────────────────────────────────────────────────
include_directories(
    ${CMAKE_SOURCE_DIR}/../include
    ${CMAKE_SOURCE_DIR}/../include/uapi
)

# ── bdfs_daemon ──────────────────────────────────────────────────────────────
if(BUILD_DAEMON)
    add_executable(bdfs_daemon
        daemon/bdfs_daemon.c
        daemon/bdfs_config.c
        daemon/bdfs_exec.c
        daemon/bdfs_jobs.c
        daemon/bdfs_netlink.c
        daemon/bdfs_socket.c
        daemon/bdfs_policy.c
    )

    target_include_directories(bdfs_daemon PRIVATE
        ${CMAKE_SOURCE_DIR}/daemon
    )

    target_link_libraries(bdfs_daemon PRIVATE pthread)

    install(TARGETS bdfs_daemon
        RUNTIME DESTINATION sbin
    )

    # Generate the systemd service unit with the correct sbin path substituted.
    # configure_file replaces @CMAKE_INSTALL_FULL_SBINDIR@ at cmake-configure
    # time so the installed unit always points at the real binary location.
    set(BDFS_DAEMON_BIN "${CMAKE_INSTALL_PREFIX}/sbin/bdfs_daemon")
    configure_file(
        ${CMAKE_SOURCE_DIR}/../configs/bdfs_daemon.service.in
        ${CMAKE_CURRENT_BINARY_DIR}/bdfs_daemon.service
        @ONLY
    )
    install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/bdfs_daemon.service
        DESTINATION lib/systemd/system
        OPTIONAL
    )

    # Default daemon config
    install(FILES
        ${CMAKE_SOURCE_DIR}/../configs/bdfs.conf
        DESTINATION etc/bdfs
        OPTIONAL
    )
endif()

# ── bdfs CLI ─────────────────────────────────────────────────────────────────
if(BUILD_CLI)
    add_executable(bdfs
        cli/bdfs_main.c
        cli/bdfs_partition.c
        cli/bdfs_export_import.c
        cli/bdfs_mount.c
        cli/bdfs_snapshot_promote_demote.c
        cli/bdfs_fetch.c
        cli/bdfs_status.c
        cli/bdfs_verify.c
        cli/bdfs_policy.c
        cli/bdfs_autosnap.c
    )

    target_include_directories(bdfs PRIVATE
        ${CMAKE_SOURCE_DIR}/cli
    )

    install(TARGETS bdfs
        RUNTIME DESTINATION bin
    )

    # Man pages
    install(FILES
        ${CMAKE_SOURCE_DIR}/../doc/bdfs.1
        DESTINATION share/man/man1
        OPTIONAL
    )
    install(FILES
        ${CMAKE_SOURCE_DIR}/../doc/bdfs_daemon.8
        DESTINATION share/man/man8
        OPTIONAL
    )

    # Boot image update script
    install(PROGRAMS
        ${CMAKE_SOURCE_DIR}/../boot/bdfs-image-update
        DESTINATION sbin
        OPTIONAL
    )

    # Boot systemd units
    install(FILES
        ${CMAKE_SOURCE_DIR}/../boot/systemd-generator/bdfs-image-update.service
        ${CMAKE_SOURCE_DIR}/../boot/systemd-generator/bdfs-image-update.timer
        DESTINATION lib/systemd/system
        OPTIONAL
    )
endif()

# ── gitlab-enhanced integration ──────────────────────────────────────────────
# When BUILD_GITLAB_ENHANCED=ON, invoke the Makefile targets that build
# bdfs-pin-helper and the gitlab-enhanced CLI from the submodule at
# integrations/gitlab-enhanced, then install them alongside bdfs.
#
# This is equivalent to running `make install-gitlab-enhanced` from the
# top-level Makefile, but wired into the CMake install step so that
# cmake --install <build_dir> covers everything in one command.
#
# Requires: go >= 1.21, pip3 (for bfg), git submodule initialised.

if(BUILD_GITLAB_ENHANCED)
    find_program(GO_EXECUTABLE go DOC "Go compiler")
    if(NOT GO_EXECUTABLE)
        message(WARNING
            "BUILD_GITLAB_ENHANCED=ON but 'go' not found. "
            "Install Go >= 1.21 or set GO_EXECUTABLE. "
            "Skipping gitlab-enhanced build.")
    else()
        set(GLE_DIR "${CMAKE_SOURCE_DIR}/../integrations/gitlab-enhanced")
        set(BFG_DIR "${CMAKE_SOURCE_DIR}/../integrations/btr-fs-git")
        set(GLE_BUILD_DIR "${CMAKE_BINARY_DIR}/gitlab-enhanced")

        # Ensure submodule is initialised
        if(NOT EXISTS "${GLE_DIR}/go.mod")
            message(STATUS "Initialising integrations/gitlab-enhanced submodule...")
            execute_process(
                COMMAND git submodule update --init --recursive
                        integrations/gitlab-enhanced
                WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/.."
                RESULT_VARIABLE _sub_result
            )
            if(NOT _sub_result EQUAL 0)
                message(WARNING "git submodule update failed for gitlab-enhanced")
            endif()
        endif()

        # Custom target: build gitlab-enhanced CLI
        add_custom_target(gitlab-enhanced-cli ALL
            COMMAND ${CMAKE_COMMAND} -E make_directory "${GLE_BUILD_DIR}"
            COMMAND ${GO_EXECUTABLE} build
                    -ldflags "-s -w"
                    -o "${GLE_BUILD_DIR}/gitlab-enhanced"
                    ./cmd/gitlab-enhanced/
            WORKING_DIRECTORY "${GLE_DIR}"
            COMMENT "Building gitlab-enhanced CLI"
            VERBATIM
        )

        # Custom target: build bdfs-pin-helper from the gitlab-enhanced root module.
        # No separate go.mod — it is part of the gitlab-enhanced module and imports
        # dwarfspin directly by module path with no replace directive.
        add_custom_target(bdfs-pin-helper ALL
            COMMAND ${GO_EXECUTABLE} build
                    -ldflags "-s -w"
                    -o "${GLE_BUILD_DIR}/bdfs-pin-helper"
                    ./tools/bdfs-pin-helper/
            WORKING_DIRECTORY "${GLE_DIR}"
            COMMENT "Building bdfs-pin-helper from gitlab-enhanced root module"
            VERBATIM
        )

        # Install both binaries
        install(PROGRAMS
            "${GLE_BUILD_DIR}/gitlab-enhanced"
            "${GLE_BUILD_DIR}/bdfs-pin-helper"
            DESTINATION bin
        )

        # Install Incus runner executor scripts
        install(PROGRAMS
            "${GLE_DIR}/runtime/incus/runner/config.sh"
            "${GLE_DIR}/runtime/incus/runner/prepare.sh"
            "${GLE_DIR}/runtime/incus/runner/run.sh"
            "${GLE_DIR}/runtime/incus/runner/cleanup.sh"
            DESTINATION lib/gitlab-runner-incus
        )

        # Install Incus profiles
        install(FILES
            "${GLE_DIR}/runtime/incus/profiles/gitlab-runner.yaml"
            "${GLE_DIR}/runtime/incus/profiles/workspace-default.yaml"
            DESTINATION share/gitlab-enhanced/profiles
            OPTIONAL
        )

        # Install gitlab-enhanced default config
        install(FILES
            "${GLE_DIR}/config/defaults.yaml"
            DESTINATION etc/gitlab-enhanced
            RENAME defaults.yaml
            OPTIONAL
        )

        message(STATUS "gitlab-enhanced integration: enabled (go=${GO_EXECUTABLE})")
    endif()
endif()

# ── Man pages ────────────────────────────────────────────────────────────────
install(FILES
    "${CMAKE_SOURCE_DIR}/../doc/bdfs.conf.5"
    DESTINATION share/man/man5
)

# ── Unit tests ───────────────────────────────────────────────────────────────
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(../tests/unit unit_tests)
endif()

# ── Summary ──────────────────────────────────────────────────────────────────
message(STATUS "")
message(STATUS "BTRFS+DwarFS userspace build configuration:")
message(STATUS "  Build daemon          : ${BUILD_DAEMON}")
message(STATUS "  Build CLI             : ${BUILD_CLI}")
message(STATUS "  Build tests           : ${BUILD_TESTS}")
message(STATUS "  ASAN                  : ${ENABLE_ASAN}")
message(STATUS "  Build gitlab-enhanced : ${BUILD_GITLAB_ENHANCED}")
message(STATUS "  Install prefix        : ${CMAKE_INSTALL_PREFIX}")
message(STATUS "")
