#!/usr/bin/env python3
"""Validate the provider-neutral AI agent budget policy."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ENGINE_PATH = ROOT / "scripts/agent-budget-governor.py"


def load_engine():
    spec = importlib.util.spec_from_file_location("agent_budget_governor", ENGINE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {ENGINE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def validate(path: Path) -> list[str]:
    engine = load_engine()
    errors: list[str] = []
    try:
        config = engine.load_yaml(path)
    except engine.BudgetError as exc:
        return [str(exc)]

    providers = config.get("providers")
    if not isinstance(providers, dict) or not providers:
        return ["providers must be a non-empty mapping"]
    if "ona" not in providers:
        errors.append("providers must include the base 'ona' OCU policy")

    for provider in providers:
        try:
            engine.provider_policy(config, provider)
        except engine.BudgetError as exc:
            errors.append(f"providers.{provider}: {exc}")

    tasks = config.get("tasks", {})
    if not isinstance(tasks, dict):
        errors.append("tasks must be a mapping")
        return errors
    for task, raw in tasks.items():
        if not isinstance(raw, dict):
            errors.append(f"tasks.{task} must be a mapping")
            continue
        required: Any = raw.get("required_units")
        if required is None:
            errors.append(f"tasks.{task}.required_units is required")
            continue
        if isinstance(required, dict):
            if not required:
                errors.append(f"tasks.{task}.required_units must not be empty")
            for provider, value in required.items():
                if provider != "default" and provider not in providers:
                    errors.append(
                        f"tasks.{task}.required_units references unknown provider {provider!r}"
                    )
                try:
                    engine.units(value, f"tasks.{task}.required_units.{provider}")
                except engine.BudgetError as exc:
                    errors.append(str(exc))
        else:
            try:
                engine.units(required, f"tasks.{task}.required_units")
            except engine.BudgetError as exc:
                errors.append(str(exc))
    return errors


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    path = Path(args[0]) if args else ROOT / "config/agent-budget.yml"
    errors = validate(path)
    if errors:
        for error in errors:
            print(f"[agent-budget-config][error] {error}", file=sys.stderr)
        return 1
    print(f"Agent budget config valid: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
