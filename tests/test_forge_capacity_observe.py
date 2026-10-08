import importlib.util
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/forge-capacity-observe.py"


def load_module():
    spec = importlib.util.spec_from_file_location("forge_capacity_observe", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_observer_counts_assigned_jobs_and_ignores_stale_runs(monkeypatch):
    module = load_module()
    now = datetime.now(timezone.utc)
    recent = (now - timedelta(minutes=5)).isoformat().replace("+00:00", "Z")
    stale = (now - timedelta(days=2)).isoformat().replace("+00:00", "Z")
    queued = (now - timedelta(minutes=3)).isoformat().replace("+00:00", "Z")

    def fake_paginated(url, field, token):
        assert token == "token"
        if "status=in_progress" in url:
            return [
                {"id": 1, "created_at": recent, "jobs_url": "https://api/jobs/1"},
                {"id": 2, "created_at": stale, "jobs_url": "https://api/jobs/2"},
            ]
        if "status=queued" in url:
            return [{"id": 3, "created_at": queued}]
        if url == "https://api/jobs/1":
            return [
                {"status": "in_progress", "runner_id": 10},
                {"status": "queued", "runner_id": 0, "started_at": recent},
                {"status": "completed", "runner_id": 0},
            ]
        raise AssertionError(f"unexpected URL: {url}")

    monkeypatch.setattr(module, "paginated", fake_paginated)
    result = module.observe_github("example", "token", 20, 21600)
    assert result["total"] == 20
    assert result["running"] == 1
    assert result["queued"] == 2
    assert result["active_runs_scanned"] == 1
    assert result["stale_runs_ignored"] == 1
    assert result["confidence"] == "medium"


def test_configured_limit_uses_safe_yaml():
    module = load_module()
    assert module.configured_limit(ROOT / "config/forge-capacity.yml", "github") == 20


def test_managed_registry_is_scoped_to_personal_owner(tmp_path):
    module = load_module()
    registry = tmp_path / "consumers.yml"
    registry.write_text(
        "consumers:\n"
        "  - name: alpha\n"
        "  - name: Example/beta\n"
        "  - name: Other/gamma\n"
        "  - name: disabled\n"
        "    disabled: true\n",
        encoding="utf-8",
    )
    assert module.managed_repositories(registry, "Example") == [
        "Example/alpha",
        "Example/beta",
        "Example/fork-sync-all",
    ]


def test_repository_observer_filters_run_statuses(monkeypatch):
    module = load_module()
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    def fake_get_json(url, token):
        if "/actions/runs?per_page=100" in url:
            return {"workflow_runs": [
                    {"id": 1, "status": "in_progress", "created_at": now, "jobs_url": "https://api/jobs/1"},
                    {"id": 2, "status": "queued", "created_at": now},
                    {"id": 3, "status": "completed", "created_at": now},
                ]}
        raise AssertionError(url)

    def fake_paginated(url, field, token):
        if url == "https://api/jobs/1":
            return [{"status": "in_progress", "runner_id": 7}]
        raise AssertionError(url)

    monkeypatch.setattr(module, "get_json", fake_get_json)
    monkeypatch.setattr(module, "paginated", fake_paginated)
    result = module.observe_github_repositories(["Example/alpha"], "Example", "token", 20, 21600)
    assert result["running"] == 1
    assert result["queued"] == 1
    assert result["confidence"] == "low"
    assert result["repository_count"] == 1
