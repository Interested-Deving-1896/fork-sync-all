import importlib.util
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/forge-capacity-manager.py"
CONFIG = ROOT / "config/forge-capacity.yml"


def load_module():
    spec = importlib.util.spec_from_file_location("forge_capacity_manager", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def manager():
    return load_module()


def config_data():
    with CONFIG.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def fresh_observation(**overrides):
    data = {
        "total": 20,
        "running": 10,
        "queued": 1,
        "oldest_age_seconds": 45,
        "confidence": "high",
        "source": "test-adapter",
        "observed_at": datetime.now(timezone.utc).isoformat(),
    }
    data.update(overrides)
    return data


def test_config_declares_every_supported_platform_and_safe_loads(manager):
    data = config_data()
    assert data["version"] == 1
    assert set(data["platforms"]) == set(manager.SUPPORTED_PLATFORMS)
    assert data["platforms"]["github"]["fallback"]["total"] == 20
    assert data["platforms"]["gitlab"]["fallback"]["total"] is None


@pytest.mark.parametrize(
    ("platform", "native", "expected"),
    [
        ("github", {"concurrent_job_limit": 20, "in_progress_jobs": 7, "queued_jobs": 2}, (20, 7, 2)),
        ("gitlab", {"concurrent": 12, "running_jobs": 6, "pending_jobs": 3}, (12, 6, 3)),
        ("gitea", {"capacity": 4, "active": 2, "waiting": 1}, (4, 2, 1)),
        ("forgejo", {"runner_capacity": 8, "active_jobs": 3, "waiting_jobs": 2}, (8, 3, 2)),
        ("codeberg", {"capacity": 2, "active": 1, "waiting": 0}, (2, 1, 0)),
    ],
)
def test_platform_native_aliases_normalize(manager, platform, native, expected):
    native["observed_at"] = datetime.now(timezone.utc).isoformat()
    result = manager.normalize_observation(platform, native)
    assert (result["total"], result["running"], result["queued"]) == expected


def test_capacity_accounts_for_emergency_reserve_and_leases(manager):
    now = datetime.now(timezone.utc)
    capacity = manager.build_capacity(
        config_data(),
        "github",
        fresh_observation(running=12),
        {"flush/1": {"slots": 2, "created_at": now.isoformat()}},
        now,
    )
    assert capacity.physical_available == 8
    assert capacity.reserved == 5
    assert capacity.available == 3
    assert capacity.active_leases == 1
    assert capacity.fresh is True


def test_noncritical_work_cannot_consume_reserved_slots(manager):
    now = datetime.now(timezone.utc)
    capacity = manager.build_capacity(config_data(), "github", fresh_observation(running=17, queued=0), {}, now)
    result = manager.admission_decision(config_data(), capacity, priority=2, slots=1)
    assert result["admitted"] is False
    assert result["reason"] == "insufficient-capacity"


def test_critical_work_can_use_reserved_slots(manager):
    now = datetime.now(timezone.utc)
    capacity = manager.build_capacity(config_data(), "github", fresh_observation(running=17, queued=50), {}, now)
    result = manager.admission_decision(config_data(), capacity, priority=1, slots=1)
    assert result["admitted"] is True
    assert result["usable_slots"] == 3


def test_stale_observation_only_admits_critical_work(manager):
    now = datetime.now(timezone.utc)
    stale = fresh_observation(observed_at=(now - timedelta(hours=1)).isoformat(), queued=0)
    capacity = manager.build_capacity(config_data(), "github", stale, {}, now)
    assert capacity.fresh is False
    assert manager.admission_decision(config_data(), capacity, 1, 1)["admitted"] is True
    decision = manager.admission_decision(config_data(), capacity, 2, 1)
    assert decision["admitted"] is False
    assert decision["reason"] == "stale-capacity-observation"


def test_unknown_fallback_is_explicit_and_protected(manager):
    now = datetime.now(timezone.utc)
    capacity = manager.build_capacity(config_data(), "gitlab", None, {}, now)
    assert capacity.total is None
    assert capacity.confidence == "unknown"
    assert capacity.source == "configured-fallback"
    assert manager.admission_decision(config_data(), capacity, 1, 1)["admitted"] is True
    assert manager.admission_decision(config_data(), capacity, 3, 1)["admitted"] is False


def test_platform_can_override_unknown_capacity_policy(manager):
    data = config_data()
    data["platforms"]["gitlab"]["unknown_capacity"] = "allow"
    capacity = manager.build_capacity(data, "gitlab", None, {}, datetime.now(timezone.utc))
    assert manager.admission_decision(data, capacity, 3, 1)["admitted"] is True


def test_queue_threshold_defers_low_priority_work(manager):
    now = datetime.now(timezone.utc)
    capacity = manager.build_capacity(config_data(), "github", fresh_observation(queued=5), {}, now)
    decision = manager.admission_decision(config_data(), capacity, 3, 1)
    assert decision["admitted"] is False
    assert decision["reason"] == "queue-threshold-reached"


def test_expired_leases_are_pruned_in_memory(manager, tmp_path):
    now = datetime.now(timezone.utc)
    path = tmp_path / "leases.json"
    path.write_text(
        json.dumps(
            {
                "leases": {
                    "expired": {"slots": 2, "created_at": (now - timedelta(hours=2)).isoformat()},
                    "active": {"slots": 1, "created_at": now.isoformat()},
                }
            }
        ),
        encoding="utf-8",
    )
    assert set(manager.read_leases(path, now, lease_ttl=1800)) == {"active"}


def test_atomic_json_round_trip(manager, tmp_path):
    path = tmp_path / "nested" / "state.json"
    manager.atomic_json(path, {"answer": 42})
    assert json.loads(path.read_text(encoding="utf-8")) == {"answer": 42}


def test_cli_record_status_admit_reserve_release(manager, tmp_path, capsys):
    observed = datetime.now(timezone.utc).isoformat()
    common = ["--config", str(CONFIG), "--platform", "github", "--cache-dir", str(tmp_path)]
    assert manager.main(common + ["record", "--total", "20", "--running", "10", "--queued", "0", "--source", "test"]) == 0
    record = json.loads(capsys.readouterr().out)
    assert record["recorded"] is True

    # Keep the static variable meaningful and show record wrote a current timestamp.
    assert manager.parse_time(record["observation"]["observed_at"]) >= manager.parse_time(observed)
    assert manager.main(common + ["status"]) == 0
    status = json.loads(capsys.readouterr().out)
    assert status["available"] == 7

    assert manager.main(common + ["admit", "--priority", "2", "--reserve", "--work-id", "sync/123"]) == 0
    admitted = json.loads(capsys.readouterr().out)
    assert admitted["admitted"] is True
    assert admitted["reserved"] is True

    assert manager.main(common + ["release", "--work-id", "sync/123"]) == 0
    released = json.loads(capsys.readouterr().out)
    assert released["released"] is True


def test_dry_run_does_not_write_observation_or_lease(manager, tmp_path, capsys):
    common = ["--config", str(CONFIG), "--platform", "github", "--cache-dir", str(tmp_path)]
    assert manager.main(common + ["record", "--total", "20", "--dry-run"]) == 0
    capsys.readouterr()
    assert not (tmp_path / "github.json").exists()

    observation = tmp_path / "input.json"
    observation.write_text(json.dumps(fresh_observation(queued=0)), encoding="utf-8")
    assert manager.main(common + ["admit", "--observation", str(observation), "--priority", "2", "--reserve", "--work-id", "dry", "--dry-run"]) == 0
    result = json.loads(capsys.readouterr().out)
    assert result["admitted"] is True
    assert result["reserved"] is False
    assert not (tmp_path / "github-leases.json").exists()


def test_reservation_retry_is_idempotent(manager, tmp_path, capsys):
    common = ["--config", str(CONFIG), "--platform", "github", "--cache-dir", str(tmp_path)]
    assert manager.main(common + ["record", "--total", "20", "--running", "16", "--queued", "0"]) == 0
    capsys.readouterr()
    request = common + ["admit", "--priority", "2", "--reserve", "--work-id", "same-work"]
    assert manager.main(request) == 0
    capsys.readouterr()
    assert manager.main(request) == 0
    retried = json.loads(capsys.readouterr().out)
    assert retried["replaced_existing_lease"] is True
    leases = json.loads((tmp_path / "github-leases.json").read_text(encoding="utf-8"))["leases"]
    assert list(leases) == ["same-work"]


def test_reserve_requires_work_id_even_when_capacity_is_full(manager, tmp_path, capsys):
    observation = tmp_path / "full.json"
    observation.write_text(json.dumps(fresh_observation(running=20)), encoding="utf-8")
    result = manager.main(
        [
            "--config",
            str(CONFIG),
            "--platform",
            "github",
            "--cache-dir",
            str(tmp_path),
            "admit",
            "--observation",
            str(observation),
            "--reserve",
        ]
    )
    assert result == 2
    assert "--work-id is required" in capsys.readouterr().err


def test_invalid_observation_fails_cleanly(manager, tmp_path, capsys):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"total": 20, "running": -1}), encoding="utf-8")
    result = manager.main(
        ["--config", str(CONFIG), "--platform", "github", "--cache-dir", str(tmp_path), "status", "--observation", str(bad)]
    )
    assert result == 2
    assert "non-negative integer" in capsys.readouterr().err
