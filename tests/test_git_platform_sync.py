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


def test_dry_run_never_creates_destination_repositories(tmp_path: Path) -> None:
    script = SCRIPT.read_text()
    match = re.search(
        r"(?ms)^_sync_repo\(\) \{\n.*?^\}\n(?=\n# ── _is_excluded)",
        script,
    )
    assert match is not None, "could not extract the production _sync_repo function"

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_git = fake_bin / "git"
    fake_git.write_text(
        "#!/usr/bin/env bash\n"
        'case "$1" in\n'
        '  clone) mkdir -p "$5" ;;\n'
        '  branch) printf "  origin/main\\n" ;;\n'
        '  tag) exit 0 ;;\n'
        '  remote) exit 0 ;;\n'
        '  *) exit 0 ;;\n'
        "esac\n"
    )
    fake_git.chmod(0o755)

    create_log = tmp_path / "create-repo-calls.log"
    harness = """
info() { printf '[info] %s\\n' "$*" >&2; }
warn() { printf '[warn] %s\\n' "$*" >&2; }
dry()  { printf '[dry] %s\\n' "$*" >&2; }
pa_init() { :; }
pa_clone_url() { printf 'https://source.invalid/%s/%s.git\\n' "$1" "$2"; }
pa_push_url() { printf 'https://destination.invalid/%s/%s.git\\n' "$1" "$2"; }
pa_create_repo() { printf '%s\\n' "$*" >> "$CREATE_LOG"; }
"""
    harness += match.group(0)
    harness += '\n_sync_repo github source source-token "" github destination dest-token "" demo true\n'

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin}{os.pathsep}{env.get('PATH', '')}",
            "CREATE_LOG": str(create_log),
            "DRY_RUN": "true",
            "FORCE": "false",
        }
    )
    result = subprocess.run(
        ["bash", "-c", harness],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "would push 1 branch(es) + 0 tag(s)" in result.stderr
    assert not create_log.exists(), "dry-run unexpectedly called pa_create_repo"
