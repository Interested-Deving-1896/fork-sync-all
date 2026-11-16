from pathlib import Path
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


def test_sync_repo_handles_tempdir_creation_failure() -> None:
    script = SCRIPT.read_text()

    assert "if ! tmpdir=$(mktemp -d); then" in script
    assert "DISK_GUARD_TRIPPED=true" in script
    assert "Could not create temporary workspace for ${repo}" in script


def test_sync_repo_cleans_tempdir_explicitly_without_return_trap() -> None:
    script = SCRIPT.read_text()

    assert 'rm -rf -- "$tmpdir"' in script
    assert 'trap "rm -rf --' not in script



def test_bare_clone_branch_discovery_uses_local_heads_refs(tmp_path: Path) -> None:
    """Exercise bare-clone ref layout locally without network access or credentials."""
    source = tmp_path / "source"
    bare = tmp_path / "source.git"
    subprocess.run(["git", "init", "-b", "main", str(source)], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(source), "config", "user.name", "Sync Test"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(source), "config", "user.email", "sync-test@example.invalid"],
        check=True,
        capture_output=True,
    )
    (source / "README.md").write_text("offline fixture\\n")
    subprocess.run(["git", "-C", str(source), "add", "README.md"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-m", "fixture"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "clone", "--bare", str(source), str(bare)],
        check=True,
        capture_output=True,
    )

    local_heads = subprocess.run(
        [
            "git", "-C", str(bare), "for-each-ref",
            "--format=%(refname:strip=2)", "refs/heads/",
        ],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    remote_tracking = subprocess.run(
        ["git", "-C", str(bare), "branch", "-r"],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()

    assert local_heads == ["main"]
    assert remote_tracking == []
