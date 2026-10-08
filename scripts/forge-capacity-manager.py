#!/usr/bin/env python3
"""Platform-neutral CI runner capacity and admission governor.

Platform adapters write small observations; this command owns normalization,
freshness, reservations, and priority-aware admission. It deliberately makes
no network calls, so an admission check cannot unexpectedly consume forge API
quota or scan every repository in an account.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping

import yaml


EXIT_DEFERRED = 3
SUPPORTED_PLATFORMS = ("github", "gitlab", "gitea", "forgejo", "codeberg")
CONFIDENCE = {"unknown": 0, "low": 1, "medium": 2, "high": 3}

FIELD_ALIASES: dict[str, dict[str, tuple[str, ...]]] = {
    "github": {
        "total": ("total", "concurrent_job_limit"),
        "running": ("running", "in_progress_jobs", "assigned_jobs"),
        "queued": ("queued", "queued_jobs", "waiting_jobs"),
    },
    "gitlab": {
        "total": ("total", "concurrent", "concurrent_job_limit"),
        "running": ("running", "running_jobs", "active_jobs"),
        "queued": ("queued", "pending_jobs", "waiting_jobs"),
    },
    "gitea": {
        "total": ("total", "capacity", "runner_capacity"),
        "running": ("running", "active", "active_jobs"),
        "queued": ("queued", "waiting", "waiting_jobs"),
    },
    "forgejo": {
        "total": ("total", "capacity", "runner_capacity"),
        "running": ("running", "active", "active_jobs"),
        "queued": ("queued", "waiting", "waiting_jobs"),
    },
    "codeberg": {
        "total": ("total", "capacity", "runner_capacity"),
        "running": ("running", "active", "active_jobs"),
        "queued": ("queued", "waiting", "waiting_jobs"),
    },
}


class CapacityError(ValueError):
    """Configuration or observation is not usable."""


@dataclass(frozen=True)
class Capacity:
    platform: str
    total: int | None
    running: int
    queued: int
    reserved: int
    available: int
    physical_available: int
    oldest_age_seconds: int | None
    confidence: str
    source: str
    observed_at: str | None
    age_seconds: int | None
    fresh: bool
    active_leases: int


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def parse_time(value: Any) -> datetime | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value), timezone.utc)
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise CapacityError(f"invalid timestamp: {value!r}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def isoformat(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def nonnegative_int(value: Any, field: str, *, nullable: bool = False) -> int | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool):
        raise CapacityError(f"{field} must be a non-negative integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise CapacityError(f"{field} must be a non-negative integer") from exc
    if result < 0:
        raise CapacityError(f"{field} must be a non-negative integer")
    return result


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except OSError as exc:
        raise CapacityError(f"cannot read config {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise CapacityError("capacity config must be a YAML mapping")
    if data.get("version") != 1:
        raise CapacityError("capacity config version must be 1")
    return data


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise CapacityError(f"cannot read state {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise CapacityError(f"state {path} must contain a JSON object")
    return data


def atomic_json(path: Path, data: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


@contextlib.contextmanager
def state_lock(cache_dir: Path, platform: str) -> Iterator[None]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    lock_path = cache_dir / f"{platform}.lock"
    with lock_path.open("a", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def platform_config(config: Mapping[str, Any], platform: str) -> dict[str, Any]:
    platforms = config.get("platforms")
    if not isinstance(platforms, dict) or platform not in platforms:
        raise CapacityError(f"platform {platform!r} is not configured")
    selected = platforms[platform]
    if not isinstance(selected, dict) or selected.get("enabled", True) is not True:
        raise CapacityError(f"platform {platform!r} is disabled")
    return selected


def configured(config: Mapping[str, Any], selected: Mapping[str, Any], key: str) -> Any:
    return selected.get(key, config.get("defaults", {}).get(key))


def first_value(data: Mapping[str, Any], names: tuple[str, ...]) -> Any:
    for name in names:
        if name in data:
            return data[name]
    return None


def normalize_observation(platform: str, data: Mapping[str, Any]) -> dict[str, Any]:
    aliases = FIELD_ALIASES[platform]
    total = nonnegative_int(first_value(data, aliases["total"]), "total", nullable=True)
    running = nonnegative_int(first_value(data, aliases["running"]) or 0, "running")
    queued = nonnegative_int(first_value(data, aliases["queued"]) or 0, "queued")
    oldest = data.get("oldest_age_seconds", data.get("oldest_age"))
    oldest = nonnegative_int(oldest, "oldest_age_seconds", nullable=True)
    confidence = str(data.get("confidence", "medium")).lower()
    if confidence not in CONFIDENCE:
        raise CapacityError(f"invalid confidence {confidence!r}")
    observed = parse_time(data.get("observed_at"))
    return {
        "total": total,
        "running": running,
        "queued": queued,
        "oldest_age_seconds": oldest,
        "confidence": confidence,
        "observed_at": isoformat(observed) if observed else None,
        "source": str(data.get("source", "adapter")),
    }


def read_leases(path: Path, now: datetime, lease_ttl: int) -> dict[str, dict[str, Any]]:
    state = load_json(path) or {}
    raw = state.get("leases", {})
    if not isinstance(raw, dict):
        raise CapacityError(f"state {path} has invalid leases")
    active: dict[str, dict[str, Any]] = {}
    for key, lease in raw.items():
        if not isinstance(lease, dict):
            continue
        created = parse_time(lease.get("created_at"))
        slots = nonnegative_int(lease.get("slots", 0), "lease slots")
        if created and (now - created).total_seconds() <= lease_ttl and slots:
            active[str(key)] = {"slots": slots, "created_at": isoformat(created)}
    return active


def build_capacity(
    config: Mapping[str, Any],
    platform: str,
    observation: Mapping[str, Any] | None,
    leases: Mapping[str, Mapping[str, Any]],
    now: datetime,
) -> Capacity:
    selected = platform_config(config, platform)
    ttl = nonnegative_int(configured(config, selected, "cache_ttl_seconds"), "cache_ttl_seconds")
    policy_reserve = nonnegative_int(configured(config, selected, "reserve_slots"), "reserve_slots")
    active_lease_slots = sum(int(lease["slots"]) for lease in leases.values())

    if observation is not None:
        normalized = normalize_observation(platform, observation)
        observed_at = parse_time(normalized["observed_at"])
        age = max(0, int((now - observed_at).total_seconds())) if observed_at else None
        fresh = age is not None and age <= ttl
    else:
        fallback = selected.get("fallback", {})
        if not isinstance(fallback, dict):
            raise CapacityError(f"platform {platform!r} fallback must be a mapping")
        normalized = normalize_observation(
            platform,
            {
                "total": fallback.get("total"),
                "running": 0,
                "queued": 0,
                "confidence": fallback.get("confidence", "unknown"),
                "source": "configured-fallback",
            },
        )
        age = None
        fresh = False

    total = normalized["total"]
    running = normalized["running"]
    reserved = policy_reserve + active_lease_slots
    physical = max(0, total - running) if total is not None else 0
    available = max(0, physical - reserved)
    return Capacity(
        platform=platform,
        total=total,
        running=running,
        queued=normalized["queued"],
        reserved=reserved,
        available=available,
        physical_available=physical,
        oldest_age_seconds=normalized["oldest_age_seconds"],
        confidence=normalized["confidence"],
        source=normalized["source"],
        observed_at=normalized["observed_at"],
        age_seconds=age,
        fresh=fresh,
        active_leases=len(leases),
    )


def priority_policy(config: Mapping[str, Any], priority: int) -> dict[str, Any]:
    policies = config.get("priorities", {})
    policy = policies.get(priority, policies.get(str(priority))) if isinstance(policies, dict) else None
    if not isinstance(policy, dict):
        raise CapacityError(f"priority {priority} is not configured")
    return policy


def exceptional_admission(mode: Any, reserve_exempt: bool, field: str) -> bool:
    normalized = str(mode).lower()
    if normalized == "allow":
        return True
    if normalized == "critical-only":
        return reserve_exempt
    if normalized == "deny":
        return False
    raise CapacityError(f"{field} must be allow, critical-only, or deny")


def admission_decision(
    config: Mapping[str, Any], capacity: Capacity, priority: int, slots: int
) -> dict[str, Any]:
    policy = priority_policy(config, priority)
    reserve_exempt = policy.get("reserve_exempt") is True
    usable = capacity.physical_available if reserve_exempt else capacity.available
    selected = platform_config(config, capacity.platform)
    if capacity.total is None:
        mode = configured(config, selected, "unknown_capacity")
        admitted = exceptional_admission(mode, reserve_exempt, "unknown_capacity")
        reason = "unknown-capacity-critical-bypass" if admitted else "unknown-capacity"
    elif not capacity.fresh:
        mode = configured(config, selected, "stale_admission")
        admitted = exceptional_admission(mode, reserve_exempt, "stale_admission")
        reason = "stale-capacity-critical-bypass" if admitted else "stale-capacity-observation"
        if admitted and usable < slots:
            admitted = False
            reason = "insufficient-capacity"
    elif capacity.queued > 0 and policy.get("max_queued") is not None and capacity.queued >= int(policy["max_queued"]):
        admitted = False
        reason = "queue-threshold-reached"
    elif usable < slots:
        admitted = False
        reason = "insufficient-capacity"
    else:
        admitted = True
        reason = "capacity-available"
    return {
        "admitted": admitted,
        "reason": reason,
        "priority": priority,
        "priority_name": str(policy.get("name", priority)),
        "requested_slots": slots,
        "usable_slots": usable,
    }


def paths(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    cache_dir = Path(args.cache_dir)
    return cache_dir, cache_dir / f"{args.platform}.json", cache_dir / f"{args.platform}-leases.json"


def observation_for(args: argparse.Namespace, cache_path: Path) -> dict[str, Any] | None:
    return load_json(Path(args.observation)) if args.observation else load_json(cache_path)


def emit(data: Mapping[str, Any]) -> None:
    json.dump(data, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


def status_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    cache_dir, cache_path, lease_path = paths(args)
    now = utc_now()
    selected = platform_config(config, args.platform)
    lease_ttl = nonnegative_int(configured(config, selected, "lease_ttl_seconds"), "lease_ttl_seconds")
    with state_lock(cache_dir, args.platform):
        leases = read_leases(lease_path, now, lease_ttl)
        observation = observation_for(args, cache_path)
        capacity = build_capacity(config, args.platform, observation, leases, now)
    emit(asdict(capacity))
    return 0


def admit_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    cache_dir, cache_path, lease_path = paths(args)
    now = utc_now()
    selected = platform_config(config, args.platform)
    lease_ttl = nonnegative_int(configured(config, selected, "lease_ttl_seconds"), "lease_ttl_seconds")
    slots = nonnegative_int(args.slots, "slots")
    if not slots:
        raise CapacityError("slots must be greater than zero")
    if args.reserve and not args.work_id:
        raise CapacityError("--work-id is required with --reserve")
    with state_lock(cache_dir, args.platform):
        leases = read_leases(lease_path, now, lease_ttl)
        # Retrying the same logical dispatch replaces its lease rather than
        # charging for the old and new lease simultaneously.
        existing_lease = leases.pop(args.work_id, None) if args.reserve else None
        observation = observation_for(args, cache_path)
        capacity = build_capacity(config, args.platform, observation, leases, now)
        decision = admission_decision(config, capacity, args.priority, slots)
        decision["capacity"] = asdict(capacity)
        decision["dry_run"] = args.dry_run
        decision["reserved"] = False
        if decision["admitted"] and args.reserve and not args.dry_run:
            leases[args.work_id] = {"slots": slots, "created_at": isoformat(now)}
            atomic_json(lease_path, {"leases": leases})
            decision["reserved"] = True
            decision["work_id"] = args.work_id
            decision["replaced_existing_lease"] = existing_lease is not None
    emit(decision)
    return 0 if decision["admitted"] else EXIT_DEFERRED


def record_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    platform_config(config, args.platform)
    cache_dir, cache_path, _ = paths(args)
    if args.input:
        raw = load_json(Path(args.input))
        if raw is None:
            raise CapacityError(f"observation file not found: {args.input}")
    else:
        raw = {
            "total": args.total,
            "running": args.running,
            "queued": args.queued,
            "oldest_age_seconds": args.oldest_age,
            "confidence": args.confidence,
            "source": args.source,
        }
    raw.setdefault("observed_at", isoformat(utc_now()))
    normalized = normalize_observation(args.platform, raw)
    with state_lock(cache_dir, args.platform):
        if not args.dry_run:
            atomic_json(cache_path, normalized)
    emit({"recorded": not args.dry_run, "dry_run": args.dry_run, "observation": normalized})
    return 0


def release_command(args: argparse.Namespace, config: Mapping[str, Any]) -> int:
    platform_config(config, args.platform)
    cache_dir, _, lease_path = paths(args)
    with state_lock(cache_dir, args.platform):
        state = load_json(lease_path) or {}
        leases = state.get("leases", {})
        if not isinstance(leases, dict):
            raise CapacityError(f"state {lease_path} has invalid leases")
        existed = args.work_id in leases
        if existed and not args.dry_run:
            del leases[args.work_id]
            atomic_json(lease_path, {"leases": leases})
    emit({"released": existed and not args.dry_run, "found": existed, "dry_run": args.dry_run, "work_id": args.work_id})
    return 0


def parser() -> argparse.ArgumentParser:
    repository = Path(__file__).resolve().parents[1]
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--config", default=str(repository / "config/forge-capacity.yml"))
    result.add_argument("--platform", choices=SUPPORTED_PLATFORMS, default=os.getenv("PLATFORM", "github"))
    result.add_argument("--cache-dir", default=os.getenv("FORGE_CAPACITY_CACHE_DIR", str(repository / ".cache/forge-capacity")))
    commands = result.add_subparsers(dest="command", required=True)

    status = commands.add_parser("status", help="print normalized capacity")
    status.add_argument("--observation", help="read an observation directly instead of the cache")
    status.set_defaults(function=status_command)

    admit = commands.add_parser("admit", help="evaluate a priority-aware admission request")
    admit.add_argument("--observation", help="read an observation directly instead of the cache")
    admit.add_argument("--priority", type=int, choices=(1, 2, 3, 4), default=3)
    admit.add_argument("--slots", type=int, default=1)
    admit.add_argument("--reserve", action="store_true", help="persist a short-lived slot lease")
    admit.add_argument("--work-id", help="unique lease identifier")
    admit.add_argument("--dry-run", action="store_true", help="evaluate without persisting a lease")
    admit.set_defaults(function=admit_command)

    record = commands.add_parser("record", help="normalize and cache an adapter observation")
    record.add_argument("--input", help="JSON observation produced by a platform adapter")
    record.add_argument("--total", type=int)
    record.add_argument("--running", type=int, default=0)
    record.add_argument("--queued", type=int, default=0)
    record.add_argument("--oldest-age", type=int)
    record.add_argument("--confidence", choices=tuple(CONFIDENCE), default="medium")
    record.add_argument("--source", default="adapter")
    record.add_argument("--dry-run", action="store_true", help="normalize without updating the cache")
    record.set_defaults(function=record_command)

    release = commands.add_parser("release", help="release a capacity lease")
    release.add_argument("--work-id", required=True)
    release.add_argument("--dry-run", action="store_true", help="report without changing lease state")
    release.set_defaults(function=release_command)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        config = load_yaml(Path(args.config))
        return int(args.function(args, config))
    except CapacityError as exc:
        print(f"[forge-capacity][error] {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
