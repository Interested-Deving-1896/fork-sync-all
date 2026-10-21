"""Provider-neutral PR / merge-request lifecycle state model.

Adapters translate provider-specific API payloads into this normalized evidence
shape. This module has no network access and performs no writes.
"""
from __future__ import annotations

from typing import Any


def check_state(checks: list[dict[str, Any]]) -> str:
    if not checks:
        return "unknown"
    active = [check for check in checks if check.get("status") != "completed"]
    if active:
        return "running"
    conclusions = [str(check.get("conclusion") or "unknown").lower() for check in checks]
    if any(value in {"failure", "timed_out", "action_required", "startup_failure"} for value in conclusions):
        return "failed"
    if any(value in {"cancelled", "stale", "unknown", "neutral"} for value in conclusions):
        return "investigate"
    if all(value in {"success", "skipped"} for value in conclusions):
        return "completed"
    return "investigate"


def classify_lifecycle(
    *,
    checks: list[dict[str, Any]],
    merge_state: str | None = None,
    mergeable: bool | None = None,
    draft: bool = False,
) -> tuple[str, str]:
    """Return conservative state and explanation from normalized provider evidence."""
    state_name = (merge_state or "").lower()
    if mergeable is False or state_name in {"dirty", "conflicting"}:
        return "BLOCKED", "Provider reports merge conflicts; resolve them before review can finish."
    if state_name in {"blocked", "unstable"}:
        return "BLOCKED", f"Provider mergeable state is {state_name}; inspect required checks and branch rules."
    if state_name == "behind":
        return "STALE", "The source branch is behind its target; check whether updating it is appropriate."

    state = check_state(checks)
    if state == "running":
        return "RUNNING", "One or more current-head checks are queued or in progress."
    if state == "failed":
        return "BLOCKED", "At least one visible check for the current head failed or requires action."
    if state == "investigate":
        return "INVESTIGATE", "A check was cancelled, neutral, stale, or inconclusive."
    if state == "unknown":
        return "UNKNOWN", "No checks are visible for the current source revision."
    if draft:
        return "DRAFT — REVIEW STATE NOT SET", "Visible checks completed, but the change remains a draft; a human must decide whether it is ready for review."
    return "REVIEW REQUIRED", "Visible checks completed; verify required checks, approvals, and provider rules."
