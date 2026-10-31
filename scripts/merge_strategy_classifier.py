#!/usr/bin/env python3
"""Deterministic, provider-neutral, read-only merge strategy classifier.

Input: JSON object on stdin with a "change_requests" array.
Output: JSON analysis on stdout. This tool never mutates a repository or merges.
Unknown evidence is fail-closed and produces "hold".
"""
from __future__ import annotations

import json
import sys
from typing import Any

STRATEGIES = {"squash", "merge_commit", "rebase", "hold"}
READINESS = {"ready_for_review", "blocked", "insufficient_evidence"}


def classify(item: dict[str, Any], policy: dict[str, Any] | None = None) -> dict[str, Any]:
    """Classify one normalized provider-neutral change request."""
    policy = policy or {}
    blockers: list[str] = []
    unknowns: list[str] = []
    evidence: list[str] = []
    rationale: list[str] = []

    required = ("id", "source_branch", "target_branch", "commit_count")
    for field in required:
        if item.get(field) is None:
            unknowns.append(f"missing:{field}")

    if item.get("discovery_complete") is not True:
        unknowns.append("discovery_incomplete")
    if item.get("topology_complete") is not True:
        unknowns.append("topology_incomplete")

    checks = item.get("checks", {})
    if checks.get("required") is None:
        unknowns.append("required_checks_unknown")
    elif checks.get("required") != "success":
        blockers.append(f"required_checks:{checks.get('required')}")

    if item.get("approval_required") is True and item.get("approved") is not True:
        blockers.append("required_review_missing")
    if item.get("mergeable") is False:
        blockers.append("merge_conflict")
    if item.get("policy_conflict") is True:
        blockers.append("policy_conflict")

    if item.get("dependency_cycle") is True:
        blockers.append("dependency_cycle")
    if item.get("dependency_evidence_complete") is not True:
        unknowns.append("dependency_evidence_incomplete")

    if unknowns:
        strategy = "hold"
        readiness = "insufficient_evidence"
        rationale.append("Insufficient evidence; fail closed rather than infer.")
    elif blockers:
        strategy = "hold"
        readiness = "blocked"
        rationale.append("One or more merge prerequisites are not satisfied.")
    else:
        commits = item.get("commit_count")
        independent = item.get("independent") is True
        stacked = item.get("stacked") is True
        meaningful = item.get("meaningful_commit_series") is True
        sha_sensitive = item.get("commit_sha_sensitive") is True
        linear_allowed = policy.get("allow_rebase", True) is True

        if stacked or item.get("integration_change") is True or meaningful:
            strategy = "merge_commit"
            rationale.append("Preserve meaningful history or verified dependency topology.")
        elif independent and sha_sensitive:
            strategy = "squash"
            rationale.append("Independent logical change; avoid unnecessary SHA rewriting.")
        elif independent and commits == 1:
            strategy = "squash"
            rationale.append("Independent single-commit change; keep target history concise.")
        elif independent and commits > 1 and item.get("commits_clean") is True and linear_allowed:
            strategy = "rebase"
            rationale.append("Independent clean commit series; linear history is appropriate.")
        elif independent and commits > 1:
            strategy = "squash"
            rationale.append("Independent change; consolidate multi-commit history.")
        else:
            strategy = "hold"
            readiness = "insufficient_evidence"
            rationale.append("Independence/topology is not established.")
            unknowns.append("independence_unknown")

        if strategy != "hold":
            readiness = "ready_for_review"
        evidence.extend([
            f"commit_count:{commits}",
            f"independent:{independent}",
            f"stacked:{stacked}",
        ])

    return {
        "provider": item.get("provider", "unknown"),
        "repository": item.get("repository", "unknown"),
        "id": item.get("id", "unknown"),
        "url": item.get("url"),
        "strategy": strategy,
        "readiness": readiness,
        "rationale": rationale,
        "evidence": evidence,
        "blockers": sorted(set(blockers)),
        "unknowns": sorted(set(unknowns)),
        "classifier_version": "0.1.0",
        "policy_version": policy.get("version", "0.1.0"),
    }


def analyze(payload: dict[str, Any]) -> dict[str, Any]:
    policy = payload.get("policy", {})
    items = payload.get("change_requests")
    if not isinstance(items, list):
        raise ValueError("'change_requests' must be a JSON array")
    results = [classify(x, policy) for x in items if isinstance(x, dict)]
    return {
        "schema_version": "1",
        "classifier_version": "0.1.0",
        "policy_version": policy.get("version", "0.1.0"),
        "read_only": True,
        "summary": {
            "total": len(results),
            "squash": sum(x["strategy"] == "squash" for x in results),
            "merge_commit": sum(x["strategy"] == "merge_commit" for x in results),
            "rebase": sum(x["strategy"] == "rebase" for x in results),
            "hold": sum(x["strategy"] == "hold" for x in results),
        },
        "change_requests": results,
    }


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        print(json.dumps(analyze(payload), indent=2, sort_keys=True))
    except (json.JSONDecodeError, ValueError, TypeError) as exc:
        print(json.dumps({"error": str(exc), "read_only": True}), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
