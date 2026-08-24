"""Regression tests for notification-inbox safety boundaries."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TRIAGE_SCRIPT = REPO_ROOT / "scripts" / "notify-triage-ids.py"
POLICY_SCRIPT = REPO_ROOT / "scripts" / "includes" / "notification-policy.sh"
NOTIFICATIONS_SCRIPT = REPO_ROOT / "scripts" / "notifications.sh"


def run_triage(tmp_path: Path, notifications: object) -> subprocess.CompletedProcess[str]:
    input_file = tmp_path / "notifications.json"
    input_file.write_text(json.dumps(notifications))
    return subprocess.run(
        ["python3", str(TRIAGE_SCRIPT), str(input_file)],
        capture_output=True,
        text=True,
        check=False,
    )


def notification(notification_id: str, owner: str, title: str) -> dict[str, object]:
    return {
        "id": notification_id,
        "repository": {"full_name": f"{owner}/repo"},
        "subject": {"title": title, "type": "CheckSuite"},
        "reason": "ci_activity",
    }


def test_triage_accepts_narrow_safe_pattern_in_managed_owner(tmp_path: Path) -> None:
    result = run_triage(
        tmp_path,
        [notification("101", "Interested-Deving-1896", "Sync btrfs-devel Branches")],
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "101"


def test_triage_rejects_generic_workflow_titles(tmp_path: Path) -> None:
    titles = ["CI", "Build", "Checks", "Quota", "Critical Deploy"]
    result = run_triage(
        tmp_path,
        [
            notification(str(index), "Interested-Deving-1896", title)
            for index, title in enumerate(titles, start=1)
        ],
    )
    assert result.returncode == 0
    assert result.stdout == ""


def test_triage_never_mutates_unmanaged_owner(tmp_path: Path) -> None:
    result = run_triage(
        tmp_path,
        [notification("202", "unrelated-owner", "dependabot: bump a dependency")],
    )
    assert result.returncode == 0
    assert result.stdout == ""


def test_triage_rejects_invalid_payload(tmp_path: Path) -> None:
    result = run_triage(tmp_path, {"message": "Bad credentials"})
    assert result.returncode != 0
    assert "expected a JSON list" in result.stderr


def run_policy(command: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", f'source "{POLICY_SCRIPT}"; {command}'],
        env={**os.environ, **env},
        capture_output=True,
        text=True,
        check=False,
    )


def test_resolver_policy_ignores_human_notifications() -> None:
    result = run_policy(
        'notification_is_ci_candidate "mention" "Issue"',
        {},
    )
    assert result.returncode != 0


def test_resolver_policy_enforces_owner_and_repo_scope() -> None:
    env = {
        "SCAN_OWNERS": "Interested-Deving-1896 OpenOS-Project-OSP",
        "OSP_REPOS_OVERRIDE": "allowed-repo",
        "REPO_FILTER": "",
    }
    assert run_policy(
        'notification_repo_in_scope "Interested-Deving-1896/allowed-repo"', env
    ).returncode == 0
    assert run_policy(
        'notification_repo_in_scope "Interested-Deving-1896/other-repo"', env
    ).returncode != 0
    assert run_policy(
        'notification_repo_in_scope "unrelated-owner/allowed-repo"', env
    ).returncode != 0


def test_cli_reports_mark_all_api_failure() -> None:
    command = (
        f'GH_TOKEN=fake source "{NOTIFICATIONS_SCRIPT}"; '
        '_api_put() { return 1; }; mark_read ""'
    )
    result = subprocess.run(
        ["bash", "-c", command], capture_output=True, text=True, check=False
    )
    assert result.returncode != 0
    assert "Failed to mark all notifications as read" in result.stderr


def test_resolver_workflow_checks_out_before_sourcing_scripts() -> None:
    workflow = (REPO_ROOT / ".github" / "workflows" / "resolve-failures.yml").read_text()
    resolve_job = workflow.index("  resolve:")
    checkout = workflow.index("actions/checkout@", resolve_job)
    source = workflow.index("source scripts/includes/fsa-mode.sh", resolve_job)
    assert checkout < source


def test_notification_web_proxy_is_loopback_only() -> None:
    script = NOTIFICATIONS_SCRIPT.read_text()
    assert "HTTPServer(('127.0.0.1', PORT)" in script
    assert "HTTPServer(('', PORT)" not in script


def test_global_clear_workflows_are_dry_run_first_and_confirmed() -> None:
    manager = (REPO_ROOT / ".github" / "workflows" / "notify-manager.yml").read_text()
    clearer = (REPO_ROOT / ".github" / "workflows" / "clear-notifications.yml").read_text()
    bootstrap = (REPO_ROOT / ".github" / "workflows" / "bootstrap-triggers.yml").read_text()

    assert 'default: "list"' in manager
    assert "confirm_all" in manager
    assert "default: repository" in clearer
    assert "scope=all requires confirm_all=true" in clearer
    assert '"${API}/notifications"' not in bootstrap
