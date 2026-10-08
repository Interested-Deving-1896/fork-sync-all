"""Regression coverage for managed/autonomous Sync All Forks routing."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


def test_sync_forks_skips_managed_consumers_before_runner_assignment() -> None:
    workflow = (ROOT / ".github/workflows/sync-forks.yml").read_text()

    assert "github.repository == 'Interested-Deving-1896/fork-sync-all'" in workflow
    assert "vars.FSA_MANAGED != 'true'" in workflow
    assert "if fsa_should_run_control_plane; then" in workflow
    assert "if: steps.fsa.outputs.enabled == 'true'" in workflow


def test_legacy_quota_monitor_schedule_is_replaced_with_managed_fallback() -> None:
    workflow = (ROOT / ".github/workflows/quota-monitor.yml").read_text()

    assert "schedule:" not in workflow
    assert "vars.FSA_MANAGED != 'true'" in workflow
    assert "if fsa_should_run_control_plane; then" in workflow
    assert "if: steps.fsa.outputs.enabled == 'true'" in workflow


def test_queue_manager_skips_managed_consumers_before_runner_assignment() -> None:
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/queue-manager.yml").read_text()
    )
    condition = workflow["jobs"]["manage"]["if"]

    assert "github.repository == 'Interested-Deving-1896/fork-sync-all'" in condition
    assert "vars.FSA_MANAGED != 'true'" in condition
    assert "github.event_name == 'schedule'" in condition


def test_quota_reserve_skips_managed_consumers_before_runner_assignment() -> None:
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/quota-reserve.yml").read_text()
    )
    condition = workflow["jobs"]["reserve"]["if"]

    assert "github.repository == 'Interested-Deving-1896/fork-sync-all'" in condition
    assert "vars.FSA_MANAGED != 'true'" in condition


def test_autonomous_fallback_bundle_is_managed_for_consumer_profiles() -> None:
    manifest = yaml.safe_load(
        (ROOT / "config/template-manifest.yml").read_text()
    )
    required = {
        ".github/workflows/sync-forks.yml",
        ".github/workflows/quota-monitor.yml",
        "scripts/sync-all-forks.sh",
        "scripts/quota-monitor.sh",
        "scripts/includes/fsa-mode.sh",
        "scripts/includes/gh-api.sh",
        "scripts/includes/quota-snapshot.sh",
        "scripts/includes/quota-instrument.sh",
    }

    for profile_name in ("infra-core", "upstream-sync"):
        profile = manifest["profiles"][profile_name]
        assert required <= set(profile["include"])
        assert ".github/workflows/sync-forks.yml" in profile["force_update"]
        assert ".github/workflows/quota-monitor.yml" in profile["force_update"]
        assert ".github/workflows/queue-manager.yml" in profile["force_update"]
        assert ".github/workflows/quota-reserve.yml" in profile["force_update"]
        assert "scripts/includes/fsa-mode.sh" in profile["force_update"]


def test_template_sync_honors_narrow_force_update_paths() -> None:
    script = (ROOT / "scripts/sync-template.sh").read_text()

    assert "resolve_profile_force_updates" in script
    assert 'path_matches_any_pattern "$dest_rel" "$profile_force_updates"' in script
    assert 'FORCE="true"' in script
    assert 'FORCE="$saved_path_force"' in script
