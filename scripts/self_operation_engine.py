#!/usr/bin/env python3
"""Provider-neutral, fail-closed self-operation orchestration for Fork-Sync-All.

The core owns planning, policy admission, lifecycle evidence, and verification.
Provider-specific reads and writes belong in adapters. Credentials are never
accepted by this module or written to its journal.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Mapping, Protocol, Sequence


class SelfOperationError(RuntimeError):
    """Base error for invalid plans, policy denials, or adapter failures."""


class PolicyDenied(SelfOperationError):
    """The requested execution mode did not satisfy its independent gates."""


@dataclass(frozen=True)
class Operation:
    operation_id: str
    capability: str
    target: str
    depends_on: tuple[str, ...] = ()
    mutating: bool = False
    expected: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.operation_id or not self.operation_id.replace("-", "").replace("_", "").isalnum():
            raise ValueError("operation_id must be a non-empty portable identifier")
        if not self.capability or not self.target:
            raise ValueError("capability and target are required")
        if self.operation_id in self.depends_on:
            raise ValueError("an operation cannot depend on itself")


@dataclass(frozen=True)
class ExecutionPolicy:
    """Explicit gates supplied by a trusted host; never populated from CLI flags alone."""
    mutation_authorized: bool = False
    protected_environment_approved: bool = False
    runtime_credential_available: bool = False
    exact_confirmation: bool = False
    allowed_targets: frozenset[str] = frozenset()


class OperationAdapter(Protocol):
    """Provider adapter contract. Implementations must expose truthful capabilities."""
    sandbox: bool
    def capabilities(self) -> set[str]: ...
    def inspect(self, operation: Operation) -> Mapping[str, Any]: ...
    def execute(self, operation: Operation, idempotency_key: str) -> Mapping[str, Any]: ...
    def verify(self, operation: Operation, execution: Mapping[str, Any]) -> Mapping[str, Any]: ...
    def reconcile(self, operation: Operation, execution: Mapping[str, Any] | None) -> Mapping[str, Any]: ...


@dataclass
class OperationResult:
    operation_id: str
    status: str
    detail: str
    evidence: Mapping[str, Any] = field(default_factory=dict)


@dataclass
class RunReport:
    run_id: str
    mode: str
    status: str
    plan_digest: str
    results: list[OperationResult]
    started_at: float
    finished_at: float | None = None

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def topological_plan(operations: Sequence[Operation]) -> list[Operation]:
    by_id = {op.operation_id: op for op in operations}
    if len(by_id) != len(operations):
        raise SelfOperationError("duplicate operation_id")
    for op in operations:
        missing = sorted(set(op.depends_on) - by_id.keys())
        if missing:
            raise SelfOperationError(f"{op.operation_id}: missing dependencies: {', '.join(missing)}")
    pending = {op.operation_id: set(op.depends_on) for op in operations}
    ordered: list[Operation] = []
    while pending:
        ready = sorted(key for key, deps in pending.items() if not deps)
        if not ready:
            raise SelfOperationError("operation dependency graph contains a cycle")
        for key in ready:
            ordered.append(by_id[key])
            pending.pop(key)
        for deps in pending.values():
            deps.difference_update(ready)
    return ordered


def _digest_plan(plan: Sequence[Operation]) -> str:
    payload = [asdict(op) for op in plan]
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=list).encode()
    return hashlib.sha256(encoded).hexdigest()


def _redact(value: Any) -> Any:
    secret_terms = ("token", "secret", "password", "authorization", "credential", "signed_url")
    if isinstance(value, Mapping):
        return {
            str(key): ("[REDACTED]" if any(term in str(key).lower() for term in secret_terms)
                       else _redact(item))
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [_redact(item) for item in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


class JsonlJournal:
    """Append-only lifecycle journal with owner-only file permissions."""
    def __init__(self, path: str | Path):
        self.path = Path(path)

    def append(self, event: Mapping[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.fchmod(fd, 0o600)
            line = json.dumps(_redact(event), sort_keys=True, separators=(",", ":")) + "\n"
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)


class SelfOperationEngine:
    def __init__(self, adapter: OperationAdapter, *, clock=time.time):
        self.adapter = adapter
        self.clock = clock

    def run(
        self,
        operations: Sequence[Operation],
        *,
        mode: str = "plan",
        policy: ExecutionPolicy = ExecutionPolicy(),
        journal: JsonlJournal | None = None,
        expected_plan_digest: str | None = None,
    ) -> RunReport:
        if mode not in {"audit", "plan", "sandbox"}:
            raise PolicyDenied("only audit, plan, and sandbox modes are available in this release")
        plan = topological_plan(operations)
        digest = _digest_plan(plan)
        if expected_plan_digest and expected_plan_digest != digest:
            raise PolicyDenied("stale plan: operation graph changed after approval")
        capabilities = self.adapter.capabilities()
        results: list[OperationResult] = []
        started = self.clock()
        run_id = f"fsa-selfop-{int(started * 1000)}-{digest[:12]}"
        report = RunReport(run_id, mode, "running", digest, results, started)
        if journal:
            journal.append({"event": "run_started", "run_id": run_id, "mode": mode, "plan_digest": digest})

        for op in plan:
            if op.capability not in capabilities:
                result = OperationResult(op.operation_id, "unsupported", "adapter lacks required capability")
            elif any(r.status not in {"verified", "audited", "planned"} for dep in op.depends_on
                     for r in results if r.operation_id == dep):
                result = OperationResult(op.operation_id, "blocked", "dependency did not complete")
            else:
                try:
                    if mode == "audit":
                        self.adapter.inspect(op)
                        result = OperationResult(op.operation_id, "audited", "read-only inspection completed",
                                                 {"inspection_completed": True})
                    elif mode == "plan":
                        result = OperationResult(op.operation_id, "planned", "operation admitted to deterministic plan")
                    else:
                        if not self.adapter.sandbox:
                            raise PolicyDenied("sandbox mode requires an adapter explicitly marked sandbox=True")
                        if not op.mutating:
                            self.adapter.inspect(op)
                            result = OperationResult(op.operation_id, "audited",
                                                      "read-only sandbox inspection completed",
                                                      {"inspection_completed": True})
                        else:
                            if not policy.mutation_authorized:
                                raise PolicyDenied("mutation authorization is required")
                            if op.target not in policy.allowed_targets:
                                raise PolicyDenied("target is not on the explicit allowlist")
                            key = hashlib.sha256(f"{run_id}:{op.operation_id}".encode()).hexdigest()
                            execution = self.adapter.execute(op, key)
                            verified = self.adapter.verify(op, execution)
                            if verified.get("verified") is not True:
                                reconciliation = self.adapter.reconcile(op, execution)
                                result = OperationResult(op.operation_id, "verification_failed",
                                                          "postconditions failed independent read-back",
                                                          {"reconciliation_attempted": True,
                                                           "reconciliation_status": str(reconciliation.get("status", "unknown"))})
                            else:
                                result = OperationResult(op.operation_id, "verified",
                                                          "execution and independent read-back verified",
                                                          {"verified": True})
                except PolicyDenied as exc:
                    result = OperationResult(op.operation_id, "denied", str(exc))
                except Exception as exc:
                    result = OperationResult(op.operation_id, "failed",
                                              f"adapter operation failed: {type(exc).__name__}")
                    try:
                        reconciliation = self.adapter.reconcile(op, None)
                        result.evidence = {"reconciliation_attempted": True,
                                           "reconciliation_status": str(reconciliation.get("status", "unknown"))}
                    except Exception:
                        result.evidence = {"reconciliation": "unavailable"}
            results.append(result)
            if journal:
                journal.append({"event": "operation_finished", "run_id": run_id, **asdict(result)})

        statuses = {r.status for r in results}
        if statuses <= {"planned"}:
            report.status = "planned"
        elif statuses <= {"audited"}:
            report.status = "audited"
        elif statuses <= {"verified", "audited"} and "verified" in statuses:
            report.status = "verified"
        elif statuses & {"failed", "denied", "verification_failed"}:
            report.status = "failed"
        else:
            report.status = "blocked"
        report.finished_at = self.clock()
        if journal:
            journal.append({"event": "run_finished", "run_id": run_id, "status": report.status,
                            "finished_at": report.finished_at})
        return report


def _load_operations(path: Path) -> list[Operation]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("version") != 1 or not isinstance(raw.get("operations"), list):
        raise SelfOperationError("manifest must be an object with version=1 and an operations array")
    operations = []
    for item in raw["operations"]:
        if not isinstance(item, dict) or not isinstance(item.get("mutating", False), bool):
            raise SelfOperationError("each operation must be an object with a boolean mutating field")
        operations.append(Operation(
            operation_id=item["id"], capability=item["capability"], target=item["target"],
            depends_on=tuple(item.get("depends_on", [])), mutating=item.get("mutating", False),
            expected=item.get("expected", {}),
        ))
    topological_plan(operations)
    return operations


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="versioned operation manifest")
    parser.add_argument("--mode", choices=("plan",), default="plan",
                        help="plan only; audit requires a real configured adapter via the Python API")
    parser.add_argument("--journal", type=Path)
    args = parser.parse_args(argv)
    operations = _load_operations(args.manifest)

    class PlanningAdapter:
        sandbox = False
        def capabilities(self): return {op.capability for op in operations}
        def inspect(self, operation): raise PolicyDenied("no provider adapter configured")
        def execute(self, operation, idempotency_key): raise PolicyDenied("no provider adapter configured")
        def verify(self, operation, execution): return {"verified": False}
        def reconcile(self, operation, execution): return {"status": "adapter_unavailable"}

    report = SelfOperationEngine(PlanningAdapter()).run(
        operations, mode=args.mode, journal=JsonlJournal(args.journal) if args.journal else None
    )
    print(json.dumps(report.as_dict(), indent=2, sort_keys=True))
    return 0 if report.status == "planned" else 2


if __name__ == "__main__":
    raise SystemExit(main())
