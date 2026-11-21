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


def test_history_rewrite_failure_is_reported_to_caller():
    rewrite = IMPORTER.split('if ! git -C "$work_dir" filter-repo', 1)[1].split("\n  return 0", 1)[0]
    assert "return 1" in rewrite
    assert "History rewrite failed" in rewrite


def test_nparent_collision_and_tree_import_failures_abort_without_fallback():
    nparent = IMPORTER.split("nparent_merge() {", 1)[1].split("# ── Sequential merge", 1)[0]
    assert "N-parent import is unsafe with a destination collision; aborting" in nparent
    assert "read-tree failed" in nparent
    assert "return 1" in nparent
    assert "sequential_merge" not in nparent


def test_nparent_source_metadata_stays_aligned_after_preparation_failures():
    assert 'src_subdirs+=("$subdir")' in IMPORTER
    assert 'local subdir="${src_subdirs[$i]}"' in IMPORTER
    assert 'N-parent source/parent count mismatch; aborting' in IMPORTER



def test_read_only_preflight_runs_before_destination_setup():
    preflight = IMPORTER.index("# Read-only preflight:")
    setup = IMPORTER.index('setup_monorepo "$mono_dir"')
    assert preflight < setup
    assert "Duplicate destination subdirectory" in IMPORTER[preflight:setup]
    assert "Unsafe destination subdirectory" in IMPORTER[preflight:setup]
    assert "only HTTPS github.com repository URLs" in IMPORTER[preflight:setup]


def test_branch_map_is_passed_as_data_not_interpolated_python_source():
    branch_map = IMPORTER.split("map_branch() {", 1)[1].split("\n}", 1)[0]
    assert 'json.loads(sys.argv[1])' in branch_map
    assert '"$BRANCH_MAP" "$src" "$MONOREPO_BRANCH"' in branch_map
    assert "json.loads('${BRANCH_MAP}')" not in branch_map
    assert "print(m.get('${src}'" not in branch_map
