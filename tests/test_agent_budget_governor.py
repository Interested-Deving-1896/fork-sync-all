import importlib.util
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/agent-budget-governor.py"


def load_module():
    spec = importlib.util.spec_from_file_location("agent_budget_governor", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def governor():
    return load_module()


@pytest.fixture()
def policy_file(tmp_path):
    path = tmp_path / "agent-budget.yml"
    path.write_text(
        "version: 1\n"
        "defaults:\n"
        "  pause_below: 10\n"
        "  resume_at: 20\n"
        "  reserve: 5\n"
        "  max_observation_age_seconds: 300\n"
        "  max_future_skew_seconds: 60\n"
        "providers:\n"
        "  nebula:\n"
        "    unit: star-credit\n"
        "    tasks:\n"
        "      provider-task:\n"
        "        required_units: 6\n"
        "tasks:\n"
        "  small:\n"
        "    required_units: 4\n"
        "  mapped:\n"
        "    required_units:\n"
        "      nebula: 11\n"
        "      default: 99\n",
        encoding="utf-8",
    )
    return path


def common(policy_file, state):
    return ["--config", str(policy_file), "--provider", "nebula", "--state", str(state)]


def observe(governor, capsys, policy_file, state, amount, when):
    result = governor.main(
        common(policy_file, state)
        + [
            "observe",
            "--available-units",
            str(amount),
            "--observed-at",
            when.isoformat(),
            "--source",
            "test-adapter",
        ]
    )
    output = json.loads(capsys.readouterr().out)
    return result, output


def test_uses_safe_yaml_and_accepts_arbitrary_provider_and_unit(governor, policy_file):
    assert "yaml.safe_load" in SCRIPT.read_text(encoding="utf-8")
    policy = governor.provider_policy(governor.load_yaml(policy_file), "nebula")
    assert policy["unit"] == "star-credit"
    assert policy["pause_below"] == 10
    assert policy["resume_at"] == 20


def test_initial_observation_in_hysteresis_band_fails_closed(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    now = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(governor, "utc_now", lambda: now)
    state = tmp_path / "state.json"
    code, output = observe(governor, capsys, policy_file, state, 15, now)
    assert code == 0
    assert output["state"]["mode"] == "paused"
    assert output["transition_reason"] == "awaiting-resume-threshold"


def test_hysteresis_pauses_low_and_only_resumes_at_high_threshold(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    clock = [datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)]
    monkeypatch.setattr(governor, "utc_now", lambda: clock[0])
    state = tmp_path / "state.json"

    _, output = observe(governor, capsys, policy_file, state, 20, clock[0])
    assert output["state"]["mode"] == "ready"

    clock[0] += timedelta(seconds=1)
    _, output = observe(governor, capsys, policy_file, state, 15, clock[0])
    assert output["state"]["mode"] == "ready"

    clock[0] += timedelta(seconds=1)
    _, output = observe(governor, capsys, policy_file, state, 9, clock[0])
    assert output["state"]["mode"] == "paused"

    clock[0] += timedelta(seconds=1)
    _, output = observe(governor, capsys, policy_file, state, 19.5, clock[0])
    assert output["state"]["mode"] == "paused"
    assert output["transition_reason"] == "awaiting-resume-threshold"

    clock[0] += timedelta(seconds=1)
    _, output = observe(governor, capsys, policy_file, state, 20, clock[0])
    assert output["state"]["mode"] == "ready"
    assert output["transition_reason"] == "resume-threshold-reached"


def test_reserve_and_per_task_requirement_control_admission(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    now = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(governor, "utc_now", lambda: now)
    state = tmp_path / "state.json"
    observe(governor, capsys, policy_file, state, 20, now)

    assert governor.main(common(policy_file, state) + ["evaluate", "--required-units", "16"]) == 0
    denied = json.loads(capsys.readouterr().out)
    assert denied["allowed"] is False
    assert denied["reason"] == "insufficient-task-budget"
    assert denied["usable_units"] == 15

    assert governor.main(common(policy_file, state) + ["check", "--task", "mapped"]) == 0
    admitted = json.loads(capsys.readouterr().out)
    assert admitted["allowed"] is True
    assert admitted["required_units"] == 11

    assert governor.main(common(policy_file, state) + ["check", "--task", "provider-task"]) == 0
    assert json.loads(capsys.readouterr().out)["required_units"] == 6


def test_check_returns_deferred_but_evaluate_only_reports(
    governor, policy_file, tmp_path, capsys
):
    missing = tmp_path / "missing.json"
    assert governor.main(common(policy_file, missing) + ["evaluate", "--task", "small"]) == 0
    evaluation = json.loads(capsys.readouterr().out)
    assert evaluation["allowed"] is False
    assert evaluation["reason"] == "unknown-observation"

    assert governor.main(common(policy_file, missing) + ["check", "--task", "small"]) == 3
    assert json.loads(capsys.readouterr().out)["action"] == "pause"


def test_stale_observation_fails_closed(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    observed = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    clock = [observed]
    monkeypatch.setattr(governor, "utc_now", lambda: clock[0])
    state = tmp_path / "state.json"
    observe(governor, capsys, policy_file, state, 50, observed)

    clock[0] += timedelta(seconds=301)
    assert governor.main(common(policy_file, state) + ["check"]) == 3
    decision = json.loads(capsys.readouterr().out)
    assert decision["fresh"] is False
    assert decision["mode"] == "paused"
    assert decision["reason"] == "stale-observation"


def test_fresh_observation_after_staleness_must_reach_resume_threshold(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    clock = [datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)]
    monkeypatch.setattr(governor, "utc_now", lambda: clock[0])
    state = tmp_path / "state.json"
    observe(governor, capsys, policy_file, state, 30, clock[0])

    clock[0] += timedelta(seconds=301)
    _, output = observe(governor, capsys, policy_file, state, 15, clock[0])
    assert output["state"]["mode"] == "paused"
    assert output["transition_reason"] == "awaiting-resume-threshold"


def test_out_of_order_observation_is_rejected_without_overwriting_state(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    now = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(governor, "utc_now", lambda: now)
    state = tmp_path / "state.json"
    observe(governor, capsys, policy_file, state, 25, now)
    before = state.read_bytes()

    code = governor.main(
        common(policy_file, state)
        + [
            "observe",
            "--available-units",
            "1",
            "--observed-at",
            (now - timedelta(seconds=1)).isoformat(),
        ]
    )
    captured = capsys.readouterr()
    assert code == 2
    assert captured.out == ""
    assert "out-of-order observation" in captured.err
    assert state.read_bytes() == before


def test_future_observation_and_untrusted_source_are_rejected(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    now = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(governor, "utc_now", lambda: now)
    state = tmp_path / "state.json"

    code = governor.main(
        common(policy_file, state)
        + [
            "observe",
            "--available-units",
            "100",
            "--observed-at",
            (now + timedelta(seconds=61)).isoformat(),
        ]
    )
    assert code == 2
    assert "too far in the future" in capsys.readouterr().err
    assert not state.exists()

    code = governor.main(
        common(policy_file, state)
        + ["observe", "--available-units", "100", "--source", "bad\nsource"]
    )
    assert code == 2
    assert "machine-readable label" in capsys.readouterr().err
    assert not state.exists()


def test_status_emits_machine_readable_state_and_effective_status(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    now = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(governor, "utc_now", lambda: now)
    state = tmp_path / "state.json"
    observe(governor, capsys, policy_file, state, 21, now)

    assert governor.main(common(policy_file, state) + ["status"]) == 0
    captured = capsys.readouterr()
    output = json.loads(captured.out)
    assert captured.err == ""
    assert output["state"]["provider"] == "nebula"
    assert output["status"]["allowed"] is True
    assert output["status"]["unit"] == "star-credit"


def test_invalid_policy_reports_only_to_stderr(governor, tmp_path, capsys):
    config = tmp_path / "invalid.yml"
    config.write_text(
        "version: 1\n"
        "defaults: {pause_below: 20, resume_at: 10, reserve: 0, max_observation_age_seconds: 1}\n"
        "providers: {custom: {unit: widgets}}\n",
        encoding="utf-8",
    )
    code = governor.main(
        ["--config", str(config), "--provider", "custom", "--state", str(tmp_path / "x.json"), "status"]
    )
    captured = capsys.readouterr()
    assert code == 2
    assert captured.out == ""
    assert "resume_at" in captured.err


def test_observation_file_aliases_are_normalized(
    governor, policy_file, tmp_path, capsys, monkeypatch
):
    now = datetime(2026, 10, 9, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(governor, "utc_now", lambda: now)
    observation = tmp_path / "observation.json"
    observation.write_text(
        json.dumps(
            {
                "provider": "nebula",
                "unit": "star-credit",
                "remaining_units": 22,
                "observed_at": now.isoformat(),
                "source": "neutral-adapter",
            }
        ),
        encoding="utf-8",
    )
    state = tmp_path / "state.json"
    assert governor.main(common(policy_file, state) + ["observe", "--input", str(observation)]) == 0
    output = json.loads(capsys.readouterr().out)
    assert output["state"]["observation"]["available_units"] == 22
    assert output["state"]["observation"]["source"] == "neutral-adapter"
