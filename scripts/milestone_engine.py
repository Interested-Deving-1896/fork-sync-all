#!/usr/bin/env python3
"""Provider-neutral, read-only milestone planning and evidence verification."""
from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import asdict, dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence


class MilestoneError(ValueError):
    """Invalid milestone manifest or dependency graph."""


VALID_STATUSES = {
    "proposed", "planned", "active", "blocked", "at_risk",
    "verifying", "completed", "cancelled", "unknown",
}
VALID_EVIDENCE = {"verified", "failed", "unknown"}


def _timestamp(value: str) -> datetime:
    if not isinstance(value, str):
        raise MilestoneError("timestamp must be an ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise MilestoneError(f"invalid ISO-8601 timestamp: {value!r}") from exc
    if parsed.tzinfo is None:
        raise MilestoneError("timestamps must include a timezone")
    return parsed.astimezone(timezone.utc)


@dataclass(frozen=True)
class CriterionResult:
    criterion_id: str
    mandatory: bool
    state: str
    evidence_ref: str | None
    explanation: str


@dataclass(frozen=True)
class MilestoneResult:
    milestone_id: str
    title: str
    status: str
    progress_percent: float
    verified_mandatory: int
    total_mandatory: int
    blockers: tuple[str, ...]
    dependencies: tuple[str, ...]
    criteria: tuple[CriterionResult, ...]


def validate_manifest(raw: Mapping[str, Any]) -> list[dict[str, Any]]:
    if not isinstance(raw, Mapping) or type(raw.get("schema_version")) is not int or raw.get("schema_version") != 1:
        raise MilestoneError("manifest must be an object with schema_version=1")
    if set(raw) - {"schema_version", "milestones"}:
        raise MilestoneError("manifest contains unsupported top-level fields")
    milestones = raw.get("milestones")
    if not isinstance(milestones, list):
        raise MilestoneError("milestones must be an array")
    allowed_milestone_fields = {
        "id", "title", "purpose", "scope", "owner", "priority", "target_date",
        "status", "depends_on", "deliverables", "acceptance_criteria",
    }
    seen: set[str] = set()
    for item in milestones:
        if not isinstance(item, dict):
            raise MilestoneError("each milestone must be an object")
        mid = item.get("id")
        if not isinstance(mid, str) or not mid.strip() or mid in seen:
            raise MilestoneError(f"milestone id is missing or duplicated: {mid!r}")
        seen.add(mid)
        unknown = set(item) - allowed_milestone_fields
        if unknown:
            raise MilestoneError(f"{mid}: unsupported fields: {', '.join(sorted(unknown))}")
        if not isinstance(item.get("title"), str) or not item["title"].strip():
            raise MilestoneError(f"{mid}: title is required")
        if "purpose" in item and not isinstance(item["purpose"], str):
            raise MilestoneError(f"{mid}: purpose must be a string")
        if "scope" in item and (
            not isinstance(item["scope"], list)
            or any(not isinstance(value, str) for value in item["scope"])
        ):
            raise MilestoneError(f"{mid}: scope must be an array of strings")
        for key in ("owner", "priority"):
            if key in item and item[key] is not None and not isinstance(item[key], str):
                raise MilestoneError(f"{mid}: {key} must be a string or null")
        target_date = item.get("target_date")
        if target_date is not None:
            if not isinstance(target_date, str):
                raise MilestoneError(f"{mid}: target_date must be an ISO date or null")
            try:
                if date.fromisoformat(target_date).isoformat() != target_date:
                    raise ValueError("non-canonical date")
            except ValueError as exc:
                raise MilestoneError(f"{mid}: target_date must use YYYY-MM-DD") from exc
        status = item.get("status", "proposed")
        if not isinstance(status, str) or status not in VALID_STATUSES:
            raise MilestoneError(f"{mid}: invalid status")
        for key in ("depends_on", "deliverables", "acceptance_criteria"):
            if not isinstance(item.get(key, []), list):
                raise MilestoneError(f"{mid}: {key} must be an array")
        dependencies = item.get("depends_on", [])
        if any(not isinstance(dep, str) or not dep.strip() for dep in dependencies):
            raise MilestoneError(f"{mid}: dependencies must be non-empty milestone IDs")
        if len(dependencies) != len(set(dependencies)):
            raise MilestoneError(f"{mid}: duplicate milestone dependencies are not allowed")
        for deliverable in item.get("deliverables", []):
            if not isinstance(deliverable, dict) or set(deliverable) - {"kind", "ref"}:
                raise MilestoneError(f"{mid}: deliverables may contain only kind and ref")
            if (not isinstance(deliverable.get("kind"), str) or not deliverable["kind"].strip()
                    or not isinstance(deliverable.get("ref"), str) or not deliverable["ref"].strip()):
                raise MilestoneError(f"{mid}: each deliverable requires non-empty kind and ref")
        criterion_ids: set[str] = set()
        for criterion in item.get("acceptance_criteria", []):
            if not isinstance(criterion, dict) or set(criterion) - {"id", "description", "mandatory", "evidence"}:
                raise MilestoneError(f"{mid}: acceptance criteria contain unsupported fields")
            cid = criterion.get("id")
            if not isinstance(cid, str) or not cid.strip() or cid in criterion_ids:
                raise MilestoneError(f"{mid}: criterion id is missing or duplicated")
            criterion_ids.add(cid)
            if not isinstance(criterion.get("description"), str) or not criterion["description"].strip():
                raise MilestoneError(f"{mid}/{cid}: description is required")
            if not isinstance(criterion.get("mandatory", True), bool):
                raise MilestoneError(f"{mid}/{cid}: mandatory must be boolean")
            evidence = criterion.get("evidence")
            if evidence is not None:
                if not isinstance(evidence, dict) or set(evidence) - {"ref", "state", "observed_at", "max_age_seconds"}:
                    raise MilestoneError(f"{mid}/{cid}: evidence contains unsupported fields")
                if not isinstance(evidence.get("state"), str) or evidence.get("state") not in VALID_EVIDENCE:
                    raise MilestoneError(f"{mid}/{cid}: evidence state is invalid")
                if not isinstance(evidence.get("ref"), str) or not evidence["ref"].strip():
                    raise MilestoneError(f"{mid}/{cid}: evidence ref is required")
                _timestamp(evidence.get("observed_at"))
                age = evidence.get("max_age_seconds")
                if age is not None and (type(age) is not int or age < 0):
                    raise MilestoneError(f"{mid}/{cid}: max_age_seconds must be a non-negative integer")
    by_id = {item["id"]: item for item in milestones}
    for item in milestones:
        missing = sorted(set(item.get("depends_on", [])) - by_id.keys())
        if missing:
            raise MilestoneError(f"{item['id']}: missing milestone dependencies: {', '.join(missing)}")
        if item["id"] in item.get("depends_on", []):
            raise MilestoneError(f"{item['id']}: milestone cannot depend on itself")
    topological_order(milestones)
    return milestones


def topological_order(milestones: Sequence[Mapping[str, Any]]) -> list[str]:
    pending = {item["id"]: set(item.get("depends_on", [])) for item in milestones}
    ordered: list[str] = []
    while pending:
        ready = sorted(mid for mid, deps in pending.items() if not deps)
        if not ready:
            raise MilestoneError("milestone dependency graph contains a cycle")
        ordered.extend(ready)
        for mid in ready:
            pending.pop(mid)
        for deps in pending.values():
            deps.difference_update(ready)
    return ordered


def _criterion_result(criterion: Mapping[str, Any], now: datetime) -> CriterionResult:
    cid = criterion["id"]
    mandatory = criterion.get("mandatory", True)
    evidence = criterion.get("evidence")
    if evidence is None:
        return CriterionResult(cid, mandatory, "missing", None, "no evidence supplied")
    observed = _timestamp(evidence["observed_at"])
    age_limit = evidence.get("max_age_seconds")
    age_seconds = (now - observed).total_seconds()
    if age_seconds < 0:
        return CriterionResult(cid, mandatory, "unknown", evidence["ref"], "evidence observation time is in the future")
    if age_limit is not None and age_seconds > age_limit:
        return CriterionResult(cid, mandatory, "stale", evidence["ref"], "evidence exceeded its freshness limit")
    state = evidence["state"]
    explanations = {
        "verified": "fresh evidence independently marks the criterion verified",
        "failed": "fresh evidence records a failed postcondition",
        "unknown": "evidence source could not establish the postcondition",
    }
    return CriterionResult(cid, mandatory, state, evidence["ref"], explanations[state])


def evaluate_manifest(raw: Mapping[str, Any], *, now: datetime | None = None) -> dict[str, Any]:
    milestones = validate_manifest(raw)
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise MilestoneError("evaluation time must include a timezone")
    current = current.astimezone(timezone.utc)
    by_id = {item["id"]: item for item in milestones}
    results: dict[str, MilestoneResult] = {}
    for mid in topological_order(milestones):
        item = by_id[mid]
        criteria = tuple(_criterion_result(c, current) for c in item.get("acceptance_criteria", []))
        mandatory = [c for c in criteria if c.mandatory]
        verified = sum(c.state == "verified" for c in mandatory)
        total = len(mandatory)
        progress = round(verified * 100.0 / total, 2) if total else 0.0
        blockers = [f"dependency:{dep}" for dep in item.get("depends_on", [])
                    if results[dep].status != "completed"]
        blockers.extend(f"criterion:{c.criterion_id}:{c.state}" for c in mandatory
                        if c.state in {"failed", "missing", "stale", "unknown"})
        if total == 0:
            blockers.append("criterion:none:mandatory_acceptance_criteria_required")
        if item.get("status") == "cancelled":
            status = "cancelled"
        elif total == 0:
            status = "unknown"
        elif blockers and any(b.startswith("dependency:") for b in blockers):
            status = "blocked"
        elif any(c.state == "failed" for c in mandatory):
            status = "blocked"
        elif total > 0 and verified == total:
            status = "completed"
        elif any(c.state in {"missing", "stale", "unknown"} for c in mandatory):
            status = "unknown" if verified == 0 else "verifying"
        elif item.get("status") == "at_risk":
            status = "at_risk"
        elif item.get("status") == "proposed":
            status = "proposed"
        elif item.get("status") == "planned":
            status = "planned"
        else:
            status = "active"
        results[mid] = MilestoneResult(
            milestone_id=mid, title=item["title"], status=status,
            progress_percent=progress, verified_mandatory=verified,
            total_mandatory=total, blockers=tuple(blockers),
            dependencies=tuple(item.get("depends_on", [])), criteria=criteria,
        )
    output = [asdict(results[mid]) for mid in topological_order(milestones)]
    canonical = json.dumps(output, sort_keys=True, separators=(",", ":"))
    return {
        "schema_version": 1,
        "generated_at": current.isoformat().replace("+00:00", "Z"),
        "plan_digest": hashlib.sha256(canonical.encode()).hexdigest(),
        "milestones": output,
        "summary": {
            "total": len(output),
            "completed": sum(x["status"] == "completed" for x in output),
            "blocked": sum(x["status"] == "blocked" for x in output),
            "unknown": sum(x["status"] == "unknown" for x in output),
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--now", help="fixed timezone-aware ISO-8601 time for reproducible evaluation")
    args = parser.parse_args(argv)
    raw = json.loads(args.manifest.read_text(encoding="utf-8"))
    now = _timestamp(args.now) if args.now else None
    print(json.dumps(evaluate_manifest(raw, now=now), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
