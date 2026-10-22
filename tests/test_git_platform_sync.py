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
        'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n"\n'
        'printf "/dev/mock 1000000 100 %s 1%% /tmp\n" "$AVAILABLE_KB"\n'
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
