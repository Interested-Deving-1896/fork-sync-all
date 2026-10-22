from pathlib import Path


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
    # is then safe to use when the local variable is gone.
    assert 'trap "rm -rf -- \'$tmpdir\'; trap - RETURN" RETURN' in script


def test_existing_destination_tags_are_checked_and_conflicts_are_not_pushed() -> None:
    script = SCRIPT.read_text()

    assert 'git ls-remote --tags dest "refs/tags/${tag}"' in script
    assert 'elif [[ "$remote_tag_sha" == "$local_tag_sha" ]]; then' in script
    assert 'Tag conflict for ${repo} tag' in script
    assert 'refspecs+=("refs/tags/${tag}:refs/tags/${tag}")' in script
    assert 'leaving destination unchanged' in script


def test_tag_inspection_failure_aborts_instead_of_blindly_pushing() -> None:
    script = SCRIPT.read_text()

    assert 'if ! remote_tag_info=$(git ls-remote --tags dest' in script
    assert 'Could not inspect destination tag' in script
    assert 'return 1' in script


def test_all_conflicting_or_matching_tags_do_not_issue_an_empty_push() -> None:
    script = SCRIPT.read_text()

    assert 'if [[ ${#refspecs[@]} -eq 0 ]]; then' in script
    assert 'No safe refs to push for ${repo}; destination remains unchanged' in script
    assert 'return 0' in script


def test_disk_space_is_reported_before_clone_and_on_clone_failure() -> None:
    script = SCRIPT.read_text()

    assert '_log_disk_space "before clone ${repo}"' in script
    assert '_log_disk_space "clone failure for ${repo}"' in script
    assert 'df -Pk "$tmp_root"' in script
    assert "possible causes include disk exhaustion, credentials, or remote/network errors" in script


def test_budget_stop_reports_reason_and_disk_space() -> None:
    script = SCRIPT.read_text()

    assert 'budget_check "$repo"' in script
    assert "runtime budget reached its safety margin" in script
    assert '_log_disk_space "budget stop before ${repo}"' in script


def test_temp_directory_creation_failure_is_reported() -> None:
    script = SCRIPT.read_text()

    assert 'tmpdir=$(mktemp -d) || {' in script
    assert "check available disk space and TMPDIR permissions" in script


def _run_sync_harness(tmp_path, git_script: str, call: str, mktemp_script=None, df_script=None, dry_run=False):
    """Run the real _sync_repo function with adapter functions and Git mocked."""
    import os
    import subprocess

    script = SCRIPT.read_text().split("# ── Main")[0]
    # The harness lives in tmp_path, so point its include lookup back at the
    # repository's real scripts directory rather than a nonexistent temp path.
    script = script.replace(
        '_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
        f'_SCRIPT_DIR="{ROOT / "scripts"}"',
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    git = fake_bin / "git"
    git.write_text("#!/usr/bin/env bash\n" + git_script)
    git.chmod(0o755)
    for command, body in (("mktemp", mktemp_script), ("df", df_script)):
        if body is not None:
            mock = fake_bin / command
            mock.write_text("#!/usr/bin/env bash\n" + body)
            mock.chmod(0o755)
    harness = tmp_path / "harness.sh"
    harness.write_text(
        script
        + '\npa_init() { :; }\n'
        + 'pa_clone_url() { echo "source-url"; }\n'
        + 'pa_push_url() { echo "dest-url"; }\n'
        + 'pa_create_repo() { :; }\n'
        + 'sleep() { :; }\n'
        + call
        + '\n'
    )
    env = os.environ.copy()
    env.update({
        "SOURCE_PLATFORM": "github", "SOURCE_ORG": "source",
        "SOURCE_TOKEN": "source-token", "DEST_PLATFORM": "gitlab",
        "DEST_ORG": "dest", "DEST_TOKEN": "dest-token",
        "PATH": str(fake_bin) + os.pathsep + env.get("PATH", ""),
        "BUDGET_MINUTES": "55", "DRY_RUN": "true" if dry_run else "false",
    })
    return subprocess.run(
        ["bash", str(harness)], env=env, text=True, capture_output=True,
        cwd=ROOT, timeout=10,
    )


def test_mocked_clone_failure_removes_temporary_clone_directory(tmp_path) -> None:
    marker = tmp_path / "temp-parent.txt"
    git_script = f"""
if [[ "$1" == "clone" ]]; then
  dirname "$5" > "{marker}"
  exit 1
fi
exit 0
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 1, result.stdout + result.stderr
    temp_parent = Path(marker.read_text().strip())
    assert not temp_parent.exists()
    assert "Clone failed for source/sample" in result.stderr


def test_mocked_tag_conflict_never_includes_tag_in_push(tmp_path) -> None:
    push_log = tmp_path / "push-args.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    exit 0
    ;;
  branch)
    echo "origin/main"
    exit 0
    ;;
  tag)
    echo "v1"
    exit 0
    ;;
  rev-parse)
    echo "local-object-sha"
    exit 0
    ;;
  ls-remote)
    echo "remote-object-sha refs/tags/v1"
    exit 0
    ;;
  push)
    printf '%s\\n' "$@" > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    args = push_log.read_text()
    assert "refs/heads/main:refs/heads/main" in args
    assert "refs/tags/v1:refs/tags/v1" not in args
    assert "Tag conflict for sample tag 'v1'" in result.stderr



def test_mocked_successful_sync_removes_temporary_clone_directory(tmp_path) -> None:
    marker = tmp_path / "temp-parent.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    dirname "$5" > "{marker}"
    exit 0
    ;;
  branch)
    echo "origin/main"
    exit 0
    ;;
  tag)
    exit 0
    ;;
  push)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not Path(marker.read_text().strip()).exists()


def test_mocked_no_refs_sync_removes_temporary_clone_directory(tmp_path) -> None:
    marker = tmp_path / "temp-parent.txt"
    push_log = tmp_path / "push-called.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    dirname "$5" > "{marker}"
    exit 0
    ;;
  branch|tag)
    exit 0
    ;;
  push)
    echo called > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not Path(marker.read_text().strip()).exists()
    assert not push_log.exists()
    assert "No refs to push for sample" in result.stderr


def test_mocked_push_failure_removes_temporary_clone_directory(tmp_path) -> None:
    marker = tmp_path / "temp-parent.txt"
    attempts = tmp_path / "push-attempts.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    dirname "$5" > "{marker}"
    exit 0
    ;;
  branch)
    echo "origin/main"
    exit 0
    ;;
  tag)
    exit 0
    ;;
  push)
    echo attempt >> "{attempts}"
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert not Path(marker.read_text().strip()).exists()
    assert attempts.read_text().splitlines() == ["attempt"] * 4
    assert "Push failed after 4 attempts" in result.stderr


def test_mocked_destination_tag_inspection_failure_aborts_and_cleans_up(tmp_path) -> None:
    marker = tmp_path / "temp-parent.txt"
    push_log = tmp_path / "push-called.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    dirname "$5" > "{marker}"
    exit 0
    ;;
  branch)
    echo "origin/main"
    exit 0
    ;;
  tag)
    echo "v1"
    exit 0
    ;;
  rev-parse)
    echo "local-object-sha"
    exit 0
    ;;
  ls-remote)
    exit 1
    ;;
  push)
    echo called > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert not Path(marker.read_text().strip()).exists()
    assert not push_log.exists()
    assert "Could not inspect destination tag 'v1'" in result.stderr



def test_mocked_disk_space_telemetry_reports_available_space(tmp_path) -> None:
    git_script = """
case "$1" in
  clone)
    mkdir -p "$5"
    exit 0
    ;;
  branch|tag)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    df_script = """
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/mock 1000 200 800 20% /tmp-mock'
"""
    result = _run_sync_harness(
        tmp_path,
        git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
        df_script=df_script,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Disk space (before clone sample): 800 KB available on /tmp-mock" in result.stderr


def test_mocked_temp_directory_failure_reports_disk_space_and_aborts(tmp_path) -> None:
    git_log = tmp_path / "git-called.txt"
    git_script = f"""
echo "$*" >> "{git_log}"
exit 1
"""
    mktemp_script = "exit 1"
    df_script = """
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/mock 1000 950 50 95% /tmp-mock'
"""
    result = _run_sync_harness(
        tmp_path,
        git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
        mktemp_script=mktemp_script,
        df_script=df_script,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Could not create temporary directory for sample" in result.stderr
    assert "Disk space (temporary directory creation failed for sample): 50 KB available on /tmp-mock" in result.stderr
    assert not git_log.exists()


def test_dry_run_reports_only_safe_tags_after_conflict_filtering(tmp_path) -> None:
    push_log = tmp_path / "push-called.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    exit 0
    ;;
  branch)
    echo "origin/main"
    exit 0
    ;;
  tag)
    printf '%s\\n' "v-conflict" "v-safe"
    exit 0
    ;;
  rev-parse)
    echo "local-object-sha-$4"
    exit 0
    ;;
  ls-remote)
    if [[ "$4" == "refs/tags/v-conflict" ]]; then
      echo "remote-object-sha refs/tags/v-conflict"
    fi
    exit 0
    ;;
  push)
    echo called > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
        dry_run=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "would push 1 branch(es) + 1 safe tag(s)" in result.stderr
    assert "would push 1 branch(es) + 2 tag(s)" not in result.stderr
    assert not push_log.exists()


def test_mocked_matching_destination_tag_is_skipped_without_empty_push(tmp_path) -> None:
    push_log = tmp_path / "push-called.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    exit 0
    ;;
  branch)
    exit 0
    ;;
  tag)
    echo "v1"
    exit 0
    ;;
  rev-parse)
    echo "same-object-sha"
    exit 0
    ;;
  ls-remote)
    echo "same-object-sha refs/tags/v1"
    exit 0
    ;;
  push)
    echo called > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not push_log.exists()
    assert "already matches at destination" in result.stderr
    assert "No safe refs to push" in result.stderr


def test_mocked_conflicting_tag_without_branches_does_not_push(tmp_path) -> None:
    push_log = tmp_path / "push-called.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    exit 0
    ;;
  branch)
    exit 0
    ;;
  tag)
    echo "v1"
    exit 0
    ;;
  rev-parse)
    echo "local-object-sha"
    exit 0
    ;;
  ls-remote)
    echo "different-object-sha refs/tags/v1"
    exit 0
    ;;
  push)
    echo called > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_sync_repo github source source-token "" gitlab dest dest-token "" sample false',
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not push_log.exists()
    assert "leaving destination unchanged" in result.stderr
    assert "No safe refs to push" in result.stderr


def test_mocked_deterministic_tag_push_rejection_is_not_retried(tmp_path) -> None:
    attempts = tmp_path / "push-attempts.txt"
    git_script = f"""
if [[ "$1" == "push" ]]; then
  echo attempt >> "{attempts}"
  echo "! [rejected] v1 -> v1 (already exists)" >&2
  exit 1
fi
exit 0
"""
    result = _run_sync_harness(
        tmp_path, git_script,
        '_git_push_retry dest refs/tags/v1:refs/tags/v1',
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert attempts.read_text().splitlines() == ["attempt"]
    assert "not retrying the same refspecs" in result.stderr
    assert "retrying in" not in result.stderr



def test_run_leg_reports_tag_conflict_while_pushing_safe_branch(tmp_path) -> None:
    push_log = tmp_path / "push-args.txt"
    git_script = f"""
case "$1" in
  clone)
    mkdir -p "$5"
    exit 0
    ;;
  branch)
    echo "origin/main"
    exit 0
    ;;
  tag)
    echo "v-conflict"
    exit 0
    ;;
  rev-parse)
    echo "local-object-sha"
    exit 0
    ;;
  ls-remote)
    echo "different-object-sha refs/tags/v-conflict"
    exit 0
    ;;
  push)
    printf '%s\\n' "$@" > "{push_log}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
"""
    result = _run_sync_harness(
        tmp_path,
        git_script,
        'pa_list_repos() { echo sample; }; _run_leg github source source-token "" gitlab dest dest-token "" true',
    )
    # A conflict is surfaced as a partial-run failure, but it must not block
    # pushing safe refs for the same repository.
    assert result.returncode == 1, result.stdout + result.stderr
    assert "synced=1 failed=0 skipped=0 tag_conflicts=1" in result.stderr
    assert "Tag conflict for sample tag 'v-conflict'" in result.stderr
    args = push_log.read_text()
    assert "refs/heads/main:refs/heads/main" in args
    assert "refs/tags/v-conflict:refs/tags/v-conflict" not in args
