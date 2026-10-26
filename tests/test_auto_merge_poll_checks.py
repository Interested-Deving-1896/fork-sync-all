"""Regression guards for direct auto-merge polling."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "auto-merge-prs.sh"


def test_direct_poll_merges_require_verified_commit_status_and_check_runs() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert "_poll_checks_state()" in script
    assert '/commits/${head_sha}/status' in script
    assert '/commits/${head_sha}/check-runs?per_page=100&page=${page}' in script
    assert 'success:more' in script
    assert 'echo "success:${head_sha}"' in script
    assert '--match-head-commit "$verified_head_sha"' in script
    assert 'success:*)' in script
    assert 'conclusion not in ("success","neutral","skipped")' in script
    assert 'failure:*|error:*) echo "failure"' in script
    assert '*) echo "error"; return 0 ;;' in script


def test_clean_mergeability_is_not_treated_as_proof_checks_passed() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    clean_case = script.split('      clean)\n', 1)[1].split('      blocked|unstable)', 1)[0]
    assert 'checks_state=$(_poll_checks_state "$pr_number")' in clean_case
    assert 'success:*)' in clean_case
    assert '--match-head-commit "$verified_head_sha"' in clean_case
    assert 'refusing direct merge' in clean_case
    assert clean_case.index('checks_state=$(_poll_checks_state "$pr_number")') < clean_case.index('gh pr merge')
