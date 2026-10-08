import importlib.util
import json
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/managed-estate-queue-drain.py"


def load_module():
    spec = importlib.util.spec_from_file_location("managed_estate_queue_drain", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_registry_is_safe_loaded_scoped_and_deduplicated(tmp_path):
    module = load_module()
    registry = tmp_path / "consumers.yml"
    registry.write_text(
        "consumers:\n"
        "  - name: alpha\n"
        "  - name: Example/alpha\n"
        "  - name: Other/beta\n"
        "  - name: ignored\n"
        "    disabled: true\n"
        "  - name: mirror\n"
        "    tier: protected\n"
        "  - name: downstream\n"
        "    tier: delegated\n",
        encoding="utf-8",
    )
    assert module.managed_repositories(registry, "Example") == [
        "Example/alpha",
        "Example/fork-sync-all",
    ]


def test_selection_preserves_tier_one_and_explicit_run_ids():
    module = load_module()
    runs = [
        module.QueueRun("Example/a", 1, "Queue Manager", "queued"),
        module.QueueRun("Example/a", 2, "Build", "queued"),
        module.QueueRun("Example/b", 3, "CI", "waiting"),
        module.QueueRun("Example/b", 4, "CI", "in_progress"),
    ]
    selected, preserved = module.select_runs(
        runs,
        frozenset({"Queue Manager"}),
        frozenset({3}),
    )
    assert [run.run_id for run in selected] == [2]
    reasons = {run.run_id: reason for run, reason in preserved}
    assert reasons == {
        1: "tier-1 workflow",
        3: "explicitly protected run ID",
        4: "status changed to in_progress",
    }


class FakeProvider:
    def __init__(self, runs, refreshed=None):
        self.runs = runs
        self.refreshed = refreshed or {}
        self.cancelled = []

    def list_pending(self, repository):
        return list(self.runs.get(repository, []))

    def refresh(self, run):
        return self.refreshed.get(run.run_id, run)

    def cancel(self, run):
        self.cancelled.append(run.run_id)


def test_dry_run_reports_without_refreshing_or_cancelling():
    module = load_module()
    provider = FakeProvider(
        {"Example/a": [module.QueueRun("Example/a", 10, "CI", "queued")]}
    )
    summary, failed = module.drain(
        provider,
        ["Example/a"],
        frozenset(),
        frozenset(),
        workers=2,
        dry_run=True,
    )
    assert failed is False
    assert provider.cancelled == []
    assert summary["eligible"] == 1
    assert summary["would_cancel"] == 1
    assert summary["cancelled"] == 0


def test_live_drain_rechecks_status_to_avoid_cancelling_started_run():
    module = load_module()
    queued = module.QueueRun("Example/a", 10, "CI", "queued")
    started = module.QueueRun("Example/a", 10, "CI", "in_progress")
    provider = FakeProvider({"Example/a": [queued]}, refreshed={10: started})
    summary, failed = module.drain(
        provider,
        ["Example/a"],
        frozenset(),
        frozenset(),
        workers=1,
        dry_run=False,
    )
    assert failed is False
    assert provider.cancelled == []
    assert summary["eligible"] == 1
    assert summary["cancelled"] == 0
    assert summary["preserved"] == 1


def test_live_drain_cancels_only_noncritical_pending_runs():
    module = load_module()
    provider = FakeProvider(
        {
            "Example/a": [
                module.QueueRun("Example/a", 10, "CI", "queued"),
                module.QueueRun("Example/a", 11, "Flush Lifecycle Manager", "queued"),
            ]
        }
    )
    summary, failed = module.drain(
        provider,
        ["Example/a"],
        frozenset({"Flush Lifecycle Manager"}),
        frozenset(),
        workers=4,
        dry_run=False,
    )
    assert failed is False
    assert provider.cancelled == [10]
    assert summary["cancelled"] == 1
    assert summary["preserved"] == 1


def test_main_emits_json_and_validates_protected_ids(monkeypatch, capsys, tmp_path):
    module = load_module()
    registry = tmp_path / "consumers.yml"
    registry.write_text("consumers: []\n", encoding="utf-8")
    tiers = tmp_path / "tiers.yml"
    tiers.write_text("tiers: []\n", encoding="utf-8")
    monkeypatch.setenv("GH_TOKEN", "token")
    monkeypatch.setattr(module.GitHubProvider, "list_pending", lambda self, repo: [])

    rc = module.main(
        [
            "--scope",
            "Example",
            "--registry",
            str(registry),
            "--tiers",
            str(tiers),
            "--protect-run-id",
            "123,456",
            "--dry-run",
        ]
    )
    assert rc == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["protected_run_ids"] == [123, 456]

    with pytest.raises(module.DrainError, match="positive integer"):
        module.parse_protected_ids(["0"])


def test_live_scan_throttles_repeated_handoffs(monkeypatch, capsys, tmp_path):
    module = load_module()
    registry = tmp_path / "consumers.yml"
    registry.write_text("consumers: []\n", encoding="utf-8")
    tiers = tmp_path / "tiers.yml"
    tiers.write_text("tiers: []\n", encoding="utf-8")
    state = tmp_path / "drain-state.json"
    calls = []

    monkeypatch.setenv("GH_TOKEN", "token")

    def list_pending(_provider, repository):
        calls.append(repository)
        return []

    monkeypatch.setattr(module.GitHubProvider, "list_pending", list_pending)
    argv = [
        "--scope",
        "Example",
        "--registry",
        str(registry),
        "--tiers",
        str(tiers),
        "--state-file",
        str(state),
        "--min-interval-seconds",
        "900",
    ]
    assert module.main(argv) == 0
    assert calls == ["Example/fork-sync-all"]
    capsys.readouterr()

    assert module.main(argv) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["skipped"] == "recent-estate-drain"
    assert calls == ["Example/fork-sync-all"]
