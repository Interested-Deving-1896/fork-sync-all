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
