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


def test_sync_repo_handles_tempdir_creation_failure() -> None:
    script = SCRIPT.read_text()

    assert "if ! tmpdir=$(mktemp -d); then" in script
    assert "DISK_GUARD_TRIPPED=true" in script
    assert "Could not create temporary workspace for ${repo}" in script


def test_sync_repo_cleans_tempdir_explicitly_without_return_trap() -> None:
    script = SCRIPT.read_text()

    assert 'rm -rf -- "$tmpdir"' in script
    assert 'trap "rm -rf --' not in script
