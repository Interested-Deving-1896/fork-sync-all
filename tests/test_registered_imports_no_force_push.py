"""Safety regression tests for registered-import synchronization refspecs."""
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sync-registered-imports.sh"


def test_registered_import_sync_never_force_pushes_branches_or_tags():
    script = SCRIPT.read_text(encoding="utf-8")
    assert "git_push_retry \"$gh_url\" 'refs/heads/*:refs/heads/*'" in script
    assert "git push \"$gh_url\" 'refs/tags/*:refs/tags/*'" in script
    assert "'+refs/heads/*:refs/heads/*'" not in script
    assert "'+refs/tags/*:refs/tags/*'" not in script


def test_script_documents_divergence_and_tag_conflict_behavior():
    script = SCRIPT.read_text(encoding="utf-8")
    assert "resolve divergence explicitly" in script
    assert "never rewrite a published target tag" in script


def test_sync_checks_free_space_before_cloning_and_reports_incomplete_run():
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'MIN_FREE_MB="${MIN_FREE_MB:-1024}"' in script
    assert 'free_mb=$(available_disk_mb)' in script
    assert 'Stopping before clone:' in script
    assert 'inventory may be incomplete' in script
    assert '[[ -z "$early_stop_reason" ]] || exit 1' in script


def test_sync_validates_disk_threshold_configuration():
    script = SCRIPT.read_text(encoding="utf-8")
    assert 'MIN_FREE_MB must be a non-negative integer' in script
