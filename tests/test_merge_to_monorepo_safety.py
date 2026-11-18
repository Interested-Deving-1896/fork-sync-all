"""Regression guards for the monorepo importer safety boundary.

These checks are intentionally static and supplement (not replace) end-to-end
Git integration tests with isolated temporary repositories.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "scripts/merge-to-monorepo.sh").read_text()
GH_API = (ROOT / "scripts/includes/gh-api.sh").read_text()


def test_importer_never_uses_force_push_fallback():
    push_section = IMPORTER.split("# Fast-forward-only push.", 1)[1]
    assert "--force-with-lease" not in push_section
    assert "--force " not in push_section
    assert "force-push is prohibited" in push_section


def test_importer_never_fakes_source_merge_with_ours_strategy():
    assert "-s ours" not in IMPORTER
    assert "ours-only merge" in IMPORTER


def test_lfs_fetch_failure_is_fatal_when_lfs_is_enabled():
    assert 'git -C "$work_dir" lfs fetch --all' in IMPORTER
    lfs_section = IMPORTER.split('git -C "$work_dir" lfs fetch --all', 1)[1].split("\n  fi", 1)[0]
    assert "return 1" in lfs_section


def test_partial_source_failure_blocks_destination_push():
    failure_guard = IMPORTER.index('if [[ "$failed" -ne 0 || "$merged" -ne "$total" ]]')
    push = IMPORTER.index('git -C "$mono_dir" push')
    assert failure_guard < push
    assert "destination was not pushed" in IMPORTER[failure_guard:push]


def test_repository_creation_uses_owner_aware_helper_and_requested_privacy():
    assert 'gh_create_repo "${MONOREPO_OWNER}" "${MONOREPO_NAME}" "${MONOREPO_PRIVATE}"' in IMPORTER
    assert 'endpoint="${_GH_API}/user/repos"' in GH_API
    assert 'endpoint="${_GH_API}/orgs/${owner}/repos"' in GH_API
    assert '"private":sys.argv[2]=="true"' in GH_API


def test_nparent_errors_do_not_fall_back_to_partial_sequential_import():
    assert 'N-parent merge failed; refusing sequential fallback or destination push' in IMPORTER
    assert 'N-parent source fetch' in IMPORTER or 'Fetch failed for' in IMPORTER
