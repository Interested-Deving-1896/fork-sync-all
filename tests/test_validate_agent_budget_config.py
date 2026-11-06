from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-agent-budget-config.py"


def load_validator():
    spec = importlib.util.spec_from_file_location("validate_agent_budget_config", VALIDATOR)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_budget_validator_accepts_provider_neutral_policy(tmp_path: Path) -> None:
    config = tmp_path / "budget.yml"
    config.write_text(
        "version: 1\n"
        "defaults:\n"
        "  pause_below: 1\n"
        "  resume_at: 2\n"
        "  reserve: 0\n"
        "  max_observation_age_seconds: 300\n"
        "providers:\n"
        "  local-runtime:\n"
        "    unit: requests\n"
        "tasks:\n"
        "  quick-task:\n"
        "    required_units: 1\n"
        "  mapped-task:\n"
        "    required_units:\n"
        "      local-runtime: 2\n"
        "      default: 1\n",
        encoding="utf-8",
    )

    assert load_validator().validate(config) == []


def test_budget_validator_rejects_unknown_task_provider(tmp_path: Path) -> None:
    config = tmp_path / "budget.yml"
    config.write_text(
        "version: 1\n"
        "defaults:\n"
        "  pause_below: 1\n"
        "  resume_at: 2\n"
        "  reserve: 0\n"
        "  max_observation_age_seconds: 300\n"
        "providers:\n"
        "  local-runtime:\n"
        "    unit: requests\n"
        "tasks:\n"
        "  quick-task:\n"
        "    required_units:\n"
        "      missing-runtime: 1\n",
        encoding="utf-8",
    )

    errors = load_validator().validate(config)
    assert any("unknown provider 'missing-runtime'" in error for error in errors)
