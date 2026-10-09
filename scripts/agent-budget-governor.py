#!/usr/bin/env python3
"""Provider-neutral compute-budget policy and admission governor.

The governor deliberately has no provider clients or network access. Provider
adapters supply normalized observations, while this command owns validation,
freshness, hysteresis, reserves, and per-task admission decisions.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import math
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping

import yaml


EXIT_DEFERRED = 3
STATE_VERSION = 1


class BudgetError(ValueError):
    """Configuration, observation, or state is not usable."""


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_time(value: Any, field: str = "timestamp") -> datetime:
    if value is None or str(value).strip() == "":
        raise BudgetError(f"{field} is required")
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise BudgetError(f"invalid {field}: {value!r}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def units(value: Any, field: str) -> float:
    if isinstance(value, bool):
        raise BudgetError(f"{field} must be a non-negative number")
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise BudgetError(f"{field} must be a non-negative number") from exc
    if not math.isfinite(result) or result < 0:
        raise BudgetError(f"{field} must be a non-negative number")
    return result


def nonnegative_int(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise BudgetError(f"{field} must be a non-negative integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise BudgetError(f"{field} must be a non-negative integer") from exc
    if result < 0:
        raise BudgetError(f"{field} must be a non-negative integer")
    return result


def source_label(value: Any) -> str:
    result = str(value or "adapter")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}", result):
        raise BudgetError("source must be a short machine-readable label")
    return result


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except OSError as exc:
        raise BudgetError(f"cannot read config {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise BudgetError(f"cannot parse config {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise BudgetError("agent budget config must be a YAML mapping")
    if data.get("version") != 1:
        raise BudgetError("agent budget config version must be 1")
    return data


def load_json(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        if str(path) == "-":
            data = json.load(sys.stdin)
        else:
            with path.open(encoding="utf-8") as handle:
                data = json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise BudgetError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise BudgetError(f"JSON {path} must contain an object")
    return data


def atomic_json(path: Path, data: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


@contextlib.contextmanager
def state_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f".{path.name}.lock")
    with lock_path.open("a", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def provider_policy(config: Mapping[str, Any], provider: str) -> dict[str, Any]:
    providers = config.get("providers")
    if not isinstance(providers, dict) or provider not in providers:
        raise BudgetError(f"provider {provider!r} is not configured")
    selected = providers[provider]
    if not isinstance(selected, dict):
        raise BudgetError(f"provider {provider!r} must be a mapping")
    if selected.get("enabled", True) is not True:
        raise BudgetError(f"provider {provider!r} is disabled")
    defaults = config.get("defaults", {})
    if not isinstance(defaults, dict):
        raise BudgetError("defaults must be a mapping")

    def setting(name: str) -> Any:
        return selected.get(name, defaults.get(name))

    unit = selected.get("unit")
    if not isinstance(unit, str) or not unit.strip():
        raise BudgetError(f"provider {provider!r} must declare a unit")
    pause_below = units(setting("pause_below"), "pause_below")
    resume_at = units(setting("resume_at"), "resume_at")
    reserve = units(setting("reserve"), "reserve")
    max_age = nonnegative_int(setting("max_observation_age_seconds"), "max_observation_age_seconds")
    max_future_skew = nonnegative_int(
        selected.get(
            "max_future_skew_seconds", defaults.get("max_future_skew_seconds", 300)
        ),
        "max_future_skew_seconds",
    )
    if resume_at < pause_below:
        raise BudgetError("resume_at must be greater than or equal to pause_below")
    return {
        "provider": provider,
        "unit": unit.strip(),
        "pause_below": pause_below,
        "resume_at": resume_at,
        "reserve": reserve,
        "max_observation_age_seconds": max_age,
        "max_future_skew_seconds": max_future_skew,
    }


def validate_state(raw: Mapping[str, Any], policy: Mapping[str, Any]) -> dict[str, Any]:
    if raw.get("version") != STATE_VERSION:
        raise BudgetError("state version must be 1")
    if raw.get("provider") != policy["provider"]:
        raise BudgetError(
            f"state provider {raw.get('provider')!r} does not match {policy['provider']!r}"
        )
    if raw.get("unit") != policy["unit"]:
        raise BudgetError(f"state unit {raw.get('unit')!r} does not match {policy['unit']!r}")
    mode = raw.get("mode")
    if mode not in {"ready", "paused"}:
        raise BudgetError("state mode must be ready or paused")
    observation = raw.get("observation")
    if not isinstance(observation, dict):
        raise BudgetError("state observation must be a mapping")
    normalized_observation = {
        "available_units": units(observation.get("available_units"), "available_units"),
        "observed_at": isoformat(parse_time(observation.get("observed_at"), "observed_at")),
        "source": source_label(observation.get("source", "adapter")),
    }
    return {
        "version": STATE_VERSION,
        "provider": policy["provider"],
        "unit": policy["unit"],
        "mode": mode,
        "observation": normalized_observation,
        "updated_at": str(raw.get("updated_at", normalized_observation["observed_at"])),
    }


def state_age(state: Mapping[str, Any], now: datetime) -> int:
    observed = parse_time(state["observation"]["observed_at"], "observed_at")
    return int((now - observed).total_seconds())


def state_is_fresh(state: Mapping[str, Any], policy: Mapping[str, Any], now: datetime) -> bool:
    age = state_age(state, now)
    return -policy["max_future_skew_seconds"] <= age <= policy["max_observation_age_seconds"]


def normalize_observation(raw: Mapping[str, Any], policy: Mapping[str, Any], now: datetime) -> dict[str, Any]:
    if "provider" in raw and raw["provider"] != policy["provider"]:
        raise BudgetError(
            f"observation provider {raw['provider']!r} does not match {policy['provider']!r}"
        )
    if "unit" in raw and raw["unit"] != policy["unit"]:
        raise BudgetError(f"observation unit {raw['unit']!r} does not match {policy['unit']!r}")
    available = None
    for name in ("available_units", "remaining_units", "remaining", "available"):
        if name in raw:
            available = raw[name]
            break
    if available is None:
        raise BudgetError("observation must include available_units")
    observed_at = parse_time(raw.get("observed_at", isoformat(now)), "observed_at")
    if (observed_at - now).total_seconds() > policy["max_future_skew_seconds"]:
        raise BudgetError("observed_at is too far in the future")
    return {
        "available_units": units(available, "available_units"),
        "observed_at": isoformat(observed_at),
        "source": source_label(raw.get("source", "adapter")),
    }


def transition_mode(
    previous: Mapping[str, Any] | None,
    observation: Mapping[str, Any],
    policy: Mapping[str, Any],
    now: datetime,
) -> tuple[str, str]:
    available = observation["available_units"]
    previous_ready = bool(
        previous
        and previous["mode"] == "ready"
        and state_is_fresh(previous, policy, now)
    )
    if available < policy["pause_below"]:
        return "paused", "below-pause-threshold"
    if previous_ready:
        return "ready", "above-pause-threshold"
    if available >= policy["resume_at"]:
        return "ready", "resume-threshold-reached"
    return "paused", "awaiting-resume-threshold"


def required_for(
    config: Mapping[str, Any], provider: str, task: str | None, explicit: Any
) -> tuple[float, str | None]:
    if explicit is not None:
        return units(explicit, "required_units"), task
    if task is None:
        return 0.0, None
    providers = config.get("providers", {})
    provider_tasks = providers.get(provider, {}).get("tasks", {})
    tasks = config.get("tasks", {})
    entry = provider_tasks.get(task) if isinstance(provider_tasks, dict) else None
    if entry is None and isinstance(tasks, dict):
        entry = tasks.get(task)
    if not isinstance(entry, dict) or "required_units" not in entry:
        raise BudgetError(f"task {task!r} has no required_units configuration")
    required = entry["required_units"]
    if isinstance(required, dict):
        if provider in required:
            required = required[provider]
        elif "default" in required:
            required = required["default"]
        else:
            raise BudgetError(f"task {task!r} has no required_units for provider {provider!r}")
    return units(required, "required_units"), task


def decision_for(
    state: Mapping[str, Any] | None,
    policy: Mapping[str, Any],
    required: float,
    task: str | None,
    now: datetime,
) -> dict[str, Any]:
    base = {
        "provider": policy["provider"],
        "unit": policy["unit"],
        "task": task,
        "required_units": required,
        "reserve_units": policy["reserve"],
        "pause_below": policy["pause_below"],
        "resume_at": policy["resume_at"],
        "max_future_skew_seconds": policy["max_future_skew_seconds"],
    }
    if state is None:
        return {
            **base,
            "allowed": False,
            "action": "pause",
            "reason": "unknown-observation",
            "mode": "paused",
            "stored_mode": None,
            "fresh": False,
            "age_seconds": None,
            "available_units": None,
            "usable_units": 0.0,
            "observed_at": None,
            "source": None,
        }
    normalized = validate_state(state, policy)
    observation = normalized["observation"]
    age = state_age(normalized, now)
    fresh = age <= policy["max_observation_age_seconds"]
    available = observation["available_units"]
    usable = max(0.0, available - policy["reserve"])
    stored_mode = normalized["mode"]
    if age < -policy["max_future_skew_seconds"]:
        allowed = False
        mode = "paused"
        reason = "future-observation"
    elif not fresh:
        allowed = False
        mode = "paused"
        reason = "stale-observation"
    elif available < policy["pause_below"]:
        allowed = False
        mode = "paused"
        reason = "below-pause-threshold"
    elif stored_mode == "paused" and available < policy["resume_at"]:
        allowed = False
        mode = "paused"
        reason = "awaiting-resume-threshold"
    elif usable < required:
        allowed = False
        mode = "ready"
        reason = "insufficient-task-budget"
    else:
        allowed = True
        mode = "ready"
        reason = "budget-available"
    return {
        **base,
        "allowed": allowed,
        "action": "proceed" if allowed else "pause",
        "reason": reason,
        "mode": mode,
        "stored_mode": stored_mode,
        "fresh": fresh,
        "age_seconds": age,
        "available_units": available,
        "usable_units": usable,
        "observed_at": observation["observed_at"],
        "source": observation["source"],
    }


def emit(data: Mapping[str, Any]) -> None:
    json.dump(data, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


def state_path(args: argparse.Namespace) -> Path:
    return Path(args.state)


def observe_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    policy = provider_policy(config, args.provider)
    path = state_path(args)
    direct_supplied = args.available_units is not None or args.observed_at is not None or args.source is not None
    if args.input and direct_supplied:
        raise BudgetError("--input cannot be combined with direct observation flags")
    if args.input:
        raw = load_json(Path(args.input))
        if raw is None:
            raise BudgetError(f"observation file not found: {args.input}")
    else:
        if args.available_units is None:
            raise BudgetError("--available-units or --input is required")
        raw = {
            "available_units": args.available_units,
            "observed_at": args.observed_at,
            "source": args.source or "manual",
        }
        if raw["observed_at"] is None:
            del raw["observed_at"]
    now = utc_now()
    observation = normalize_observation(raw, policy, now)
    with state_lock(path):
        old_raw = load_json(path)
        previous = validate_state(old_raw, policy) if old_raw is not None else None
        if previous is not None:
            previous_at = parse_time(previous["observation"]["observed_at"], "observed_at")
            incoming_at = parse_time(observation["observed_at"], "observed_at")
            if incoming_at < previous_at:
                raise BudgetError(
                    f"out-of-order observation {observation['observed_at']} is older than {previous['observation']['observed_at']}"
                )
        mode, transition_reason = transition_mode(previous, observation, policy, now)
        state = {
            "version": STATE_VERSION,
            "provider": policy["provider"],
            "unit": policy["unit"],
            "mode": mode,
            "observation": observation,
            "updated_at": isoformat(now),
        }
        atomic_json(path, state)
    emit({"recorded": True, "transition_reason": transition_reason, "state": state})
    return 0


def evaluate_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    policy = provider_policy(config, args.provider)
    raw = load_json(state_path(args))
    required, task = required_for(config, args.provider, args.task, args.required_units)
    emit(decision_for(raw, policy, required, task, utc_now()))
    return 0


def check_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    policy = provider_policy(config, args.provider)
    raw = load_json(state_path(args))
    required, task = required_for(config, args.provider, args.task, args.required_units)
    decision = decision_for(raw, policy, required, task, utc_now())
    emit(decision)
    return 0 if decision["allowed"] else EXIT_DEFERRED


def status_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    policy = provider_policy(config, args.provider)
    raw = load_json(state_path(args))
    decision = decision_for(raw, policy, 0.0, None, utc_now())
    emit({"state": validate_state(raw, policy) if raw is not None else None, "status": decision})
    return 0


def add_task_request(parser: argparse.ArgumentParser) -> None:
    request = parser.add_mutually_exclusive_group()
    request.add_argument("--task", help="task identifier from the policy config")
    request.add_argument("--required-units", type=float, help="one-off task requirement")


def parser() -> argparse.ArgumentParser:
    repository = Path(__file__).resolve().parents[1]
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--config", default=str(repository / "config/agent-budget.yml"))
    result.add_argument("--provider", default=os.getenv("AI_AGENT_PROVIDER"))
    result.add_argument("--state", required=True, help="provider state JSON input/output path")
    commands = result.add_subparsers(dest="command", required=True)

    observe = commands.add_parser("observe", help="normalize an adapter observation and update state")
    observe.add_argument("--input", help="JSON observation file; use - for stdin")
    observe.add_argument("--available-units", type=float)
    observe.add_argument("--observed-at")
    observe.add_argument("--source")
    observe.set_defaults(function=observe_command)

    evaluate = commands.add_parser("evaluate", help="evaluate policy without enforcing the result")
    add_task_request(evaluate)
    evaluate.set_defaults(function=evaluate_command)

    check = commands.add_parser("check", help="exit 3 when work must pause")
    add_task_request(check)
    check.set_defaults(function=check_command)

    status = commands.add_parser("status", help="print normalized state and current policy status")
    status.set_defaults(function=status_command)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if not args.provider:
            raise BudgetError("--provider or AI_AGENT_PROVIDER is required")
        config = load_yaml(Path(args.config))
        return int(args.function(args, config))
    except BudgetError as exc:
        print(f"[agent-budget][error] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
