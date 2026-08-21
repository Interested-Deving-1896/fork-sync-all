"""Regression coverage for the consolidated token-rotation lifecycle."""

from __future__ import annotations

import importlib.util
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROTATE_WORKFLOW = (ROOT / ".github/workflows/rotate-token.yml").read_text()
HEALTH_WORKFLOW = (ROOT / ".github/workflows/token-health.yml").read_text()
MONITOR_SCRIPT = (ROOT / "scripts/token-monitor.sh").read_text()
ROTATE_SCRIPT = (ROOT / "scripts/rotate-token.sh").read_text()


def load_cleanup_module():
    path = ROOT / "scripts/post-rotation-cleanup.py"
    spec = importlib.util.spec_from_file_location("post_rotation_cleanup", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_cleanup_is_integrated_and_old_workflow_is_removed():
    assert not (ROOT / ".github/workflows/cancel-post-rotation.yml").exists()
    assert "needs: rotate" in ROTATE_WORKFLOW
    assert "run: python3 scripts/post-rotation-cleanup.py" in ROTATE_WORKFLOW
    assert ROTATE_WORKFLOW.count("GH_TOKEN: ${{ github.token }}") >= 2


def test_cleanup_runs_only_after_successful_rotation_job():
    cleanup = load_cleanup_module()
    cutoff = datetime(2026, 8, 21, 12, 0, tzinfo=timezone.utc)
    base = {"id": 10, "event": "schedule", "created_at": "2026-08-21T11:59:00Z"}
    assert cleanup.should_cancel(
        base, current_run_id=99, rotation_started=cutoff
    ) == (True, "pre-rotation")
    assert cleanup.should_cancel(
        {**base, "event": "workflow_dispatch"},
        current_run_id=99,
        rotation_started=cutoff,
    ) == (False, "manual-dispatch")
    assert cleanup.should_cancel(
        {**base, "id": 99}, current_run_id=99, rotation_started=cutoff
    ) == (False, "rotation-run")
    assert cleanup.should_cancel(
        {**base, "created_at": "2026-08-21T12:00:00Z"},
        current_run_id=99,
        rotation_started=cutoff,
    ) == (False, "post-rotation")


def test_rotation_value_is_masked_before_third_party_actions():
    mask = ROTATE_WORKFLOW.index("- name: Mask rotation value")
    harden = ROTATE_WORKFLOW.index("- name: Harden runner")
    checkout = ROTATE_WORKFLOW.index("- name: Checkout")
    assert mask < harden < checkout
    assert "::add-mask::${value_line}" in ROTATE_WORKFLOW
    assert 'pop("token_value", None)' in ROTATE_WORKFLOW
    assert "toJSON(inputs)" not in ROTATE_WORKFLOW


def test_rotation_failures_are_visible_and_expiry_commit_is_pushed():
    assert "Failed to update ${SECRET_NAME} in ${REPO}" in ROTATE_SCRIPT
    assert 'git -C "$REPO_ROOT" push origin' in ROTATE_SCRIPT
    assert 'warn() { echo "[rotate-token]' in ROTATE_SCRIPT
    assert 'ok()   { echo "[rotate-token] ✓ $*" >&2; }' in ROTATE_SCRIPT


def test_health_monitor_has_one_reconciliation_path_and_consistent_defaults():
    assert 'WARN_DAYS: ${{ inputs.warn_days || \'45\' }}' in HEALTH_WORKFLOW
    assert "- name: Reconcile alert issue" in HEALTH_WORKFLOW
    assert "gh issue edit" in HEALTH_WORKFLOW
    assert "gh issue comment" not in HEALTH_WORKFLOW
    assert 'workflows:\n      - "Rotate Secret Token"' in HEALTH_WORKFLOW
    assert "github.event.workflow_run.conclusion == 'success'" in HEALTH_WORKFLOW


def test_monitor_reports_invalid_gitlab_tokens_and_writes_full_issue_body():
    assert 'echo "invalid (HTTP ${http_code})"' in MONITOR_SCRIPT
    assert 'echo "## Token Monitor Alert"' in MONITOR_SCRIPT
    assert "top-level alert accurate" in MONITOR_SCRIPT
    assert 'WARN_DAYS="${WARN_DAYS:-45}"' in MONITOR_SCRIPT


def test_template_profiles_receive_integrated_cleanup_script():
    manifest = (ROOT / "config/template-manifest.yml").read_text()
    assert manifest.count("scripts/post-rotation-cleanup.py") == 4
    assert "cancel-post-rotation.yml" not in manifest


def test_priority_tiers_have_one_source_of_truth():
    reserve = (ROOT / "scripts/quota-reserve.sh").read_text()
    assert "WORKFLOW_TIER[" not in reserve
    assert 'TIERS_FILE="${SCRIPT_DIR}/../config/workflow-priority-tiers.yml"' in reserve
