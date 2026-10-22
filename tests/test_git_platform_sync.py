from pathlib import Path
import os
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/git-platform-sync.sh"


def test_pull_leg_swaps_platform_credentials_and_hosts() -> None:
    script = SCRIPT.read_text()

    assert (
        '_run_leg "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" \\\n'
        '      "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" "false"'
    ) in script


def test_sync_helpers_use_direction_specific_credentials() -> None:
    script = SCRIPT.read_text()

    assert 'PLATFORM_TOKEN="$from_token"' in script
    assert 'PLATFORM_HOST="$from_host" pa_init "$from_platform" "$from_host"' in script
    assert 'PLATFORM_TOKEN="$to_token"' in script
    assert 'PLATFORM_HOST="$to_host" pa_init "$to_platform" "$to_host"' in script


def test_return_trap_captures_tmpdir_before_local_scope_ends() -> None:
    script = SCRIPT.read_text()

    # Double quotes expand tmpdir when the trap is installed; the quoted path
    # is then safe to use when RETURN fires after the local variable is gone.
    assert 'trap "rm -rf -- \'$tmpdir\'" RETURN' in script


def _run_disk_guard(tmp_path: Path, available_kb: str, df_exit: int = 0) -> subprocess.CompletedProcess[str]:
    script = SCRIPT.read_text()
    disk_free = re.search(r"(?ms)^_disk_free_mb\(\) \{.*?^\}", script)
    guard = re.search(r"(?ms)^_has_min_disk_space\(\) \{.*?^\}", script)
    assert disk_free and guard, "could not locate disk guard functions"

    function_file = tmp_path / "disk-guard-functions.sh"
    function_file.write_text(disk_free.group(0) + "\n" + guard.group(0) + "\n")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    df_stub = bin_dir / "df"
    df_stub.write_text(
        "#!/bin/sh\n"
        'if [ "$DF_EXIT" -ne 0 ]; then exit "$DF_EXIT"; fi\n'
        'printf "%s\\n" "Filesystem 1024-blocks Used Available Capacity Mounted on" "/dev/mock 1000000 100 $AVAILABLE_KB 1% /tmp"\n'
    )
    df_stub.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}:{env.get('PATH', '')}",
        "AVAILABLE_KB": available_kb,
        "DF_EXIT": str(df_exit),
    })
    return subprocess.run(
        [
            "bash", "-c",
            f"source {function_file!s}; warn() {{ printf '%s\\n' \"$*\" >&2; }}; "
            "MIN_FREE_DISK_MB=512; _has_min_disk_space /tmp",
        ],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def test_low_disk_guard_returns_distinct_stop_code(tmp_path: Path) -> None:
    result = _run_disk_guard(tmp_path, "1000")
    assert result.returncode == 3
    assert "Low disk space" in result.stderr


def test_disk_guard_allows_sufficient_space(tmp_path: Path) -> None:
    result = _run_disk_guard(tmp_path, "1048576")
    assert result.returncode == 0


def test_disk_guard_fails_closed_when_df_is_unavailable(tmp_path: Path) -> None:
    result = _run_disk_guard(tmp_path, "0", df_exit=1)
    assert result.returncode == 4
    assert "refusing to start clone" in result.stderr


def test_sync_has_configurable_low_disk_guard_and_stops_leg() -> None:
    script = SCRIPT.read_text()

    assert 'MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-512}"' in script
    assert '_has_min_disk_space "$tmpdir"' in script
    assert 'stop_reason=low_disk_space' in script
    assert 'Low disk space:' in script


def test_sync_accounting_distinguishes_conflicts_and_incomplete_runs() -> None:
    script = SCRIPT.read_text()

    assert 'local synced=0 failed=0 skipped=0 conflicts=0 incomplete=false stop_reason=none' in script
    assert 'tag_conflicts=${conflicts}' in script
    assert 'reason=${stop_reason}' in script
    assert 'remaining repositories were not processed' in script
    assert '_report_disk_free "$tmpdir"' in script


def test_tag_conflict_is_reported_without_retrying() -> None:
    script = SCRIPT.read_text()

    assert "tag .*already exists|already exists.*tag|would clobber existing tag" in script
    assert "Destination tag conflict — not retrying; existing tags are preserved" in script
    assert script.index("Destination tag conflict — not retrying") < script.index("retrying in ${wait}s")


def _run_push_retry(tmp_path: Path, push_output: str, push_exit: int) -> subprocess.CompletedProcess[str]:
    script = SCRIPT.read_text()
    match = re.search(r"(?ms)^_git_push_retry\(\) \{.*?^\}", script)
    assert match, "could not locate _git_push_retry function"

    function_file = tmp_path / "push-retry-function.sh"
    function_file.write_text(match.group(0) + "\n")

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    git_stub = bin_dir / "git"
    git_stub.write_text(
        "#!/bin/sh\n"
        'printf x >> "$CALLS_FILE"\n'
        'printf "%s\\n" "$PUSH_OUTPUT"\n'
        'exit "$PUSH_EXIT"\n'
    )
    git_stub.chmod(0o755)
    sleep_stub = bin_dir / "sleep"
    sleep_stub.write_text("#!/bin/sh\nexit 0\n")
    sleep_stub.chmod(0o755)

    calls_file = tmp_path / "git-calls"
    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}:{env.get('PATH', '')}",
        "CALLS_FILE": str(calls_file),
        "PUSH_OUTPUT": push_output,
        "PUSH_EXIT": str(push_exit),
        "SOURCE_TOKEN": "source-secret",
        "DEST_TOKEN": "dest-secret",
    })
    result = subprocess.run(
        [
            "bash", "-c",
            f"source {function_file!s}; warn() {{ printf '%s\\n' \"$*\" >&2; }}; "
            "_git_push_retry dest refs/tags/v1",
        ],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    result.call_count = len(calls_file.read_text()) if calls_file.exists() else 0
    return result


def test_tag_conflict_exits_without_retrying_real_push_function(tmp_path: Path) -> None:
    result = _run_push_retry(
        tmp_path,
        "remote: error: tag v1 already exists",
        1,
    )

    assert result.returncode == 2
    assert result.call_count == 1
    assert "Destination tag conflict — not retrying" in result.stderr


def test_transient_push_failure_keeps_bounded_retries(tmp_path: Path) -> None:
    result = _run_push_retry(tmp_path, "remote: temporary network error", 1)

    assert result.returncode == 1
    assert result.call_count == 4
    assert "Push failed after 3 attempts" in result.stderr



def _run_tag_preflight(tmp_path: Path, remote_oid: str, mode: str = "ok") -> subprocess.CompletedProcess[str]:
    script = SCRIPT.read_text()
    match = re.search(r"(?ms)^_preflight_destination_tags\(\) \{.*?^\}", script)
    assert match, "could not locate destination tag preflight function"

    function_file = tmp_path / "tag-preflight-function.sh"
    function_file.write_text(match.group(0) + "\n")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    git_stub = bin_dir / "git"
    git_stub.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "ls-remote" ]; then\n'
        '  [ "$PREFLIGHT_MODE" != "lookup-fail" ] || exit 1\n'
        '  printf "%s\\n" "$REMOTE_TAG_LINE"\n'
        '  exit 0\n'
        "fi\n"
        'if [ "$1" = "rev-parse" ]; then printf "%s\\n" "local-oid"; exit 0; fi\n'
        "exit 9\n"
    )
    git_stub.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}:{env.get('PATH', '')}",
        "PREFLIGHT_MODE": mode,
        "REMOTE_TAG_LINE": f"{remote_oid}\trefs/tags/v1",
    })
    return subprocess.run(
        [
            "bash", "-c",
            f"source {function_file!s}; warn() {{ printf '%s\\n' \"$*\" >&2; }}; "
            "_preflight_destination_tags dest v1",
        ],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def test_tag_preflight_detects_conflict_before_any_push() -> None:
    script = SCRIPT.read_text()
    assert '_preflight_destination_tags dest "${tags[@]}"' in script
    assert script.index('_preflight_destination_tags dest "${tags[@]}"') < script.index('_git_push_retry dest "${refspecs[@]}"')


def test_tag_preflight_rejects_different_destination_tag_oid(tmp_path: Path) -> None:
    result = _run_tag_preflight(tmp_path, "remote-oid")
    assert result.returncode == 2
    assert "not pushing any refs" in result.stderr


def test_tag_preflight_allows_matching_destination_tag_oid(tmp_path: Path) -> None:
    result = _run_tag_preflight(tmp_path, "local-oid")
    assert result.returncode == 0


def test_tag_preflight_fails_closed_if_remote_tag_lookup_fails(tmp_path: Path) -> None:
    result = _run_tag_preflight(tmp_path, "remote-oid", mode="lookup-fail")
    assert result.returncode == 1
    assert "refusing to push refs" in result.stderr


def test_tag_preflight_allows_tag_missing_from_destination(tmp_path: Path) -> None:
    result = _run_tag_preflight(tmp_path, "")
    assert result.returncode == 0


def test_tag_preflight_skips_remote_lookup_when_no_tags(tmp_path: Path) -> None:
    script = SCRIPT.read_text()
    match = re.search(r"(?ms)^_preflight_destination_tags\(\) \{.*?^\}", script)
    assert match, "could not locate destination tag preflight function"
    function_file = tmp_path / "tag-preflight-empty-function.sh"
    function_file.write_text(match.group(0) + "\n")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    git_stub = bin_dir / "git"
    git_stub.write_text("#!/bin/sh\nexit 9\n")
    git_stub.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
    result = subprocess.run(
        [
            "bash", "-c",
            f'source {function_file!s}; warn() {{ printf "%s\\n" "$*" >&2; }}; _preflight_destination_tags dest',
        ],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0

def _run_sync_cleanup(tmp_path: Path, mode: str) -> subprocess.CompletedProcess[str]:
    script = SCRIPT.read_text()
    match = re.search(r"(?ms)^_sync_repo\(\) \{.*?(?=^_is_excluded\(\))", script)
    assert match, "could not locate _sync_repo function"

    function_file = tmp_path / "sync-repo-function.sh"
    function_file.write_text(match.group(0) + "\n")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    temp_root = tmp_path / "temp-root"
    temp_root.mkdir()
    mktemp_stub = bin_dir / "mktemp"
    mktemp_stub.write_text(
        "#!/bin/sh\n"
        'mkdir -p "$TMP_ROOT/sync-temp"\n'
        'printf "%s\\n" "$TMP_ROOT/sync-temp"\n'
    )
    mktemp_stub.chmod(0o755)
    git_stub = bin_dir / "git"
    git_stub.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "clone" ]; then\n'
        '  if [ "$SYNC_MODE" = "clone-fail" ]; then exit 1; fi\n'
        '  mkdir -p "$5"\n'
        '  exit 0\n'
        'fi\n'
        'if [ "$1" = "branch" ] && [ "$SYNC_MODE" = "push-fail" ]; then printf "%s\\n" "origin/main"; fi\n'
        'exit 0\n'
    )
    git_stub.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}:{env.get('PATH', '')}",
        "TMP_ROOT": str(temp_root),
        "SYNC_MODE": mode,
        "SOURCE_TOKEN": "source-secret",
        "DEST_TOKEN": "dest-secret",
    })
    command = (
        f"source {function_file!s}; "
        "info() { :; }; warn() { :; }; dry() { :; }; "
        "_has_min_disk_space() { return 0; }; _report_disk_free() { :; }; _preflight_destination_tags() { return 0; }; "
        "pa_init() { :; }; pa_clone_url() { printf '%s\\n' source-url; }; "
        "pa_push_url() { printf '%s\\n' dest-url; }; pa_create_repo() { :; }; "
        "_git_push_retry() { return 1; }; "
        "_sync_repo github src source-secret '' github dst dest-secret '' demo true"
    )
    return subprocess.run(["bash", "-c", command], text=True, capture_output=True, env=env, check=False)


def test_temp_clone_is_removed_after_success_with_no_refs(tmp_path: Path) -> None:
    result = _run_sync_cleanup(tmp_path, "no-refs")
    assert result.returncode == 0
    assert not (tmp_path / "temp-root" / "sync-temp").exists()


def test_temp_clone_is_removed_after_clone_failure(tmp_path: Path) -> None:
    result = _run_sync_cleanup(tmp_path, "clone-fail")
    assert result.returncode == 1
    assert not (tmp_path / "temp-root" / "sync-temp").exists()


def test_temp_clone_is_removed_after_push_failure(tmp_path: Path) -> None:
    result = _run_sync_cleanup(tmp_path, "push-fail")
    assert result.returncode == 1
    assert not (tmp_path / "temp-root" / "sync-temp").exists()
