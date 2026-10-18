"""Regression tests for fail-closed auto-merge protection detection."""

from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "auto-merge-prs.sh"


def run_detector(tmp_path: Path, responses: str, *, base: str = "main") -> str:
    source = SCRIPT.read_text(encoding="utf-8")
    match = re.search(
        r"(_detect_mechanism\(\) \{.*?\n\})\n\nMECHANISM=",
        source,
        flags=re.S,
    )
    assert match, "mechanism detector function should remain extractable"
    harness = f"""
GH_API="https://api.github.com"
REPO="owner/repo"
BASE_FILTER="{base}"
MERGE_MECHANISM=""
{responses}
{match.group(1)}
_detect_mechanism
"""
    result = subprocess.run(
        ["bash", "-c", harness],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


def test_active_default_branch_ruleset_selects_native_even_if_classic_api_forbidden(tmp_path):
    responses = r'''
gh_get() {
  case "$1" in
    */repos/owner/repo) printf '{"default_branch":"main"}' ;;
    */branches/main/protection) return 22 ;;
    */rulesets\?per_page=100) printf '[{"id":1,"target":"branch","enforcement":"active"}]' ;;
    */rulesets/1) printf '{"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI Required"}]}}]}' ;;
    *) return 1 ;;
  esac
}
'''
    assert run_detector(tmp_path, responses) == "native"


def test_unknown_protection_fails_closed_when_rulesets_are_unavailable(tmp_path):
    responses = r'''
gh_get() {
  case "$1" in
    */repos/owner/repo) printf '{"default_branch":"main"}' ;;
    */branches/main/protection) return 22 ;;
    */rulesets\?per_page=100) return 22 ;;
    *) return 1 ;;
  esac
}
'''
    assert run_detector(tmp_path, responses) == "unsafe"


def test_confirmed_no_required_checks_keeps_poll_mode(tmp_path):
    responses = r'''
gh_get() {
  case "$1" in
    */repos/owner/repo) printf '{"default_branch":"main"}' ;;
    */branches/main/protection) printf '{"required_status_checks":null}' ;;
    */rulesets\?per_page=100) printf '[]' ;;
    *) return 1 ;;
  esac
}
'''
    assert run_detector(tmp_path, responses) == "poll"
