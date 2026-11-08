#!/usr/bin/env python3
"""Resolve Fork-Sync-All repository policy without making remote changes."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover - environment diagnostic
    raise SystemExit("PyYAML is required: python -m pip install pyyaml") from exc


def load_yaml(path: Path) -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: top-level YAML value must be a mapping")
    return data


def resolve_policy(baseline: dict, consumers: dict, repo_name: str) -> dict:
    if baseline.get("schema_version") != 1:
        raise ValueError("unsupported repository policy schema_version")
    entries = consumers.get("consumers", []) or []
    # Prefer an exact owner-qualified match. Only use short-name fallback for
    # short input; otherwise a mirror and its canonical source can collide.
    if "/" in repo_name:
        matches = [
            item for item in entries
            if isinstance(item, dict) and item.get("name") == repo_name
        ]
    else:
        matches = [
            item for item in entries
            if isinstance(item, dict) and item.get("name") == repo_name
        ]
    if len(matches) > 1:
        raise ValueError(f"duplicate consumer entries for {repo_name}")
    consumer = matches[0] if matches else {}
    if consumer.get("disabled", False):
        return {"repo": repo_name, "status": "disabled", "policy_version": baseline.get("policy_version")}
    if consumer.get("tier") in ("protected", "delegated"):
        return {
            "repo": repo_name,
            "status": consumer["tier"],
            "policy_version": baseline.get("policy_version"),
            "delegated_to": consumer.get("delegated_to"),
        }

    profile = consumer.get("policy_profile") or consumer.get("profile") or "standalone"
    profiles = baseline.get("profiles", {}) or {}
    if profile not in profiles:
        raise ValueError(f"unknown policy profile {profile!r} for {repo_name}")

    defaults = baseline.get("defaults", {}) or {}
    selected = profiles[profile]
    override = (baseline.get("repository_overrides", {}) or {}).get(repo_name, {}) or {}
    policy = {
        "repository": dict(defaults.get("repository", {}) or {}),
        "branch_protection": dict(defaults.get("branch_protection", {}) or {}),
        "require_ci": bool(selected.get("require_ci", False)),
        "required_status_checks": list(selected.get("required_status_checks", []) or []),
    }
    policy["repository"].update(override.get("repository", {}) or {})
    policy["branch_protection"].update(override.get("branch_protection", {}) or {})
    if "require_ci" in override:
        policy["require_ci"] = bool(override["require_ci"])
    if "required_status_checks" in override:
        policy["required_status_checks"] = list(override["required_status_checks"] or [])
    if policy["require_ci"] and not policy["required_status_checks"]:
        raise ValueError(f"{repo_name}: require_ci=true but no required_status_checks are configured")
    return {
        "repo": repo_name,
        "status": "resolved",
        "profile": profile,
        "policy_version": baseline.get("policy_version"),
        **policy,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=Path("config/repository-policy-baseline.yml"))
    parser.add_argument("--consumers", type=Path, default=Path("config/template-consumers.yml"))
    parser.add_argument("--repo", required=True, help="consumer name, optionally owner-qualified")
    args = parser.parse_args()
    try:
        result = resolve_policy(load_yaml(args.baseline), load_yaml(args.consumers), args.repo)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"repository-policy: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
