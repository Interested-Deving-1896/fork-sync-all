import os
import re
import subprocess
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
    # is then safe to use when RETURN fires after the local variable is gone.
    assert 'trap "rm -rf -- \'$tmpdir\'" RETURN' in script


def test_dry_run_never_creates_destination_repositories() -> None:
    script = SCRIPT.read_text()

    assert 'if [[ "$DRY_RUN" != "true" && "$create_missing" == "true" ]]; then' in script
    assert 'pa_create_repo "$to_org" "$repo" "Mirror of ${from_platform}/${from_org}/${repo}"' in script
    assert '[[ "$DRY_RUN" == "true" ]] && info "Dry run — no pushes will occur."' in script





def test_dry_run_does_not_call_destination_repo_creation(tmp_path: Path) -> None:
    script = SCRIPT.read_text()
    match = re.search(r"(?ms)^_sync_repo\(\) \{.*?(?=^_is_excluded\(\))", script)
    assert match, "could not locate _sync_repo function"

    function_file = tmp_path / "sync-repo-function.sh"
    function_file.write_text(match.group(0) + "\n", encoding="utf-8")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    temp_root = tmp_path / "temp-root"
    temp_root.mkdir()
    calls = tmp_path / "calls.log"

    mktemp_stub = bin_dir / "mktemp"
    mktemp_stub.write_text(
        "#!/bin/sh\n"
        'mkdir -p "$TMP_ROOT/sync-temp"\n'
        'printf "%s\\n" "$TMP_ROOT/sync-temp"\n',
        encoding="utf-8",
    )
    mktemp_stub.chmod(0o755)
    git_stub = bin_dir / "git"
    git_stub.write_text(
        "#!/bin/sh\n"
        'case "$1" in\n'
        '  clone) mkdir -p "$5"; exit 0 ;;\n'
        '  branch) printf "%s\\n" "origin/main"; exit 0 ;;\n'
        '  tag) exit 0 ;;\n'
        '  remote) exit 0 ;;\n'
        '  *) exit 0 ;;\n'
        'esac\n',
        encoding="utf-8",
    )
    git_stub.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "PATH": f"{bin_dir}{os.pathsep}{env.get('PATH', '')}",
        "TMP_ROOT": str(temp_root),
        "CALLS_LOG": str(calls),
        "DRY_RUN": "true",
        "FORCE": "false",
        "SOURCE_TOKEN": "source-secret",
        "DEST_TOKEN": "dest-secret",
    })
    command = (
        f"source {function_file!s}; "
        "info() { :; }; warn() { printf '%s\\n' \"$*\" >&2; }; "
        "dry() { printf '%s\\n' \"$*\" >&2; }; "
        "_has_min_disk_space() { return 0; }; _report_disk_free() { :; }; "
        "pa_init() { :; }; pa_clone_url() { printf '%s\\n' source-url; }; "
        "pa_push_url() { printf '%s\\n' dest-url; }; "
        'pa_create_repo() { printf "%s\\n" "$*" >> "$CALLS_LOG"; }; '
        "_preflight_destination_tags() { return 0; }; "
        '_sync_repo github src source-secret "" gitlab dst dest-secret "" demo true'
    )
    result = subprocess.run(
        ["bash", "-c", command],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "would push 1 branch(es) + 0 tag(s)" in result.stderr
    assert not calls.exists(), "pa_create_repo must not run in dry-run mode"
    assert not (temp_root / "sync-temp").exists(), "temporary clone should be cleaned up"
