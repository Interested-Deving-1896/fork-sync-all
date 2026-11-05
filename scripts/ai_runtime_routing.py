#!/usr/bin/env python3
"""Provider-neutral evidence model and fail-closed workload routing policy.

This module never probes hardware itself. Platform adapters supply bounded,
read-only evidence; the router accepts acceleration only when evidence is
fresh, explicitly verified, and covers every requested workload constraint.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Iterable, Mapping


@dataclass(frozen=True)
class BackendEvidence:
    backend_id: str
    state: str
    observed_at: str
    source: str
    workloads: frozenset[str] = field(default_factory=frozenset)
    data_types: frozenset[str] = field(default_factory=frozenset)
    device_memory_bytes: int | None = None
    device_id: str | None = None
    diagnostic: str = ""

    def __post_init__(self) -> None:
        if not self.backend_id or not self.source:
            raise ValueError("backend_id and source are required")
        if self.state not in {"candidate", "verified-usable", "not-detected", "error"}:
            raise ValueError("unsupported backend evidence state")
        if self.device_memory_bytes is not None and self.device_memory_bytes < 0:
            raise ValueError("device_memory_bytes cannot be negative")
        # Require a timezone-aware ISO timestamp to prevent local-time ambiguity.
        parsed = datetime.fromisoformat(self.observed_at.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("observed_at must include a timezone")


@dataclass(frozen=True)
class WorkloadRequest:
    workload: str
    data_type: str = "float32"
    min_device_memory_bytes: int = 0
    allow_cpu_fallback: bool = True

    def __post_init__(self) -> None:
        if not self.workload or not self.data_type:
            raise ValueError("workload and data_type are required")
        if self.min_device_memory_bytes < 0:
            raise ValueError("min_device_memory_bytes cannot be negative")


@dataclass(frozen=True)
class RouteDecision:
    backend_id: str
    reason: str
    evidence_source: str | None = None


def _age_seconds(observed_at: str, now: datetime) -> float:
    observed = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    if observed.tzinfo is None:
        raise ValueError("observed_at must include a timezone")
    return (now - observed).total_seconds()


def route_workload(
    request: WorkloadRequest,
    evidence: Iterable[BackendEvidence],
    *,
    now: datetime | None = None,
    max_evidence_age_seconds: int = 300,
    backend_priority: tuple[str, ...] = ("qualcomm-qnn", "apple-coreml", "directml", "cuda", "rocm", "openvino", "vulkan", "opencl", "onnxruntime"),
) -> RouteDecision:
    """Choose only a fresh, explicitly verified backend with complete evidence.

    Candidate presence, device visibility, KPort tiers, and runtime package
    installation are intentionally insufficient. Unknown capabilities deny
    acceleration. CPU is the deterministic fallback unless the request forbids it.
    """
    if max_evidence_age_seconds < 0:
        raise ValueError("max_evidence_age_seconds cannot be negative")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    by_id: dict[str, BackendEvidence] = {}
    for item in evidence:
        by_id[item.backend_id] = item

    for backend_id in backend_priority:
        item = by_id.get(backend_id)
        if item is None or item.state != "verified-usable":
            continue
        try:
            age = _age_seconds(item.observed_at, current)
        except ValueError:
            continue
        if age < 0 or age > max_evidence_age_seconds:
            continue
        if request.workload not in item.workloads or request.data_type not in item.data_types:
            continue
        if item.device_memory_bytes is None or item.device_memory_bytes < request.min_device_memory_bytes:
            continue
        return RouteDecision(backend_id, "fresh verified evidence satisfies the requested workload", item.source)

    if request.allow_cpu_fallback:
        return RouteDecision("cpu", "no fresh verified accelerator evidence satisfies this workload")
    return RouteDecision("unavailable", "no verified accelerator satisfies the workload and CPU fallback is disabled")


def runtime_candidate_inventory() -> list[dict[str, object]]:
    """Report optional runtime packages/providers as candidates, never verified devices."""
    candidates: list[dict[str, object]] = []
    try:
        import importlib.util
        installed = importlib.util.find_spec("onnxruntime") is not None
    except (ImportError, ValueError):
        installed = False
    candidates.append({
        "id": "onnxruntime",
        "installed": installed,
        "state": "candidate" if installed else "not-detected",
        "verified_usable": False,
        "verification_note": "Package presence is not proof of an available provider or usable device.",
    })
    return candidates
