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

def test_tag_conflict_is_reported_without_retrying() -> None:
    script = SCRIPT.read_text()

    assert "tag .*already exists|already exists.*tag|would clobber existing tag" in script
    assert "Destination tag conflict — not retrying; existing tags are preserved" in script
    assert script.index("Destination tag conflict — not retrying") < script.index("retrying in ${wait}s")
