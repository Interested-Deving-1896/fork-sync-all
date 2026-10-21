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

def test_existing_destination_tags_are_checked_and_conflicts_are_not_pushed() -> None:
    script = SCRIPT.read_text()

    assert 'git ls-remote --tags dest "refs/tags/${tag}"' in script
    assert 'remote_tag_sha == "$local_tag_sha"' in script
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
