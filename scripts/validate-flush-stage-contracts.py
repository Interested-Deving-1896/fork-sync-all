#!/usr/bin/env python3
"""Validate and resolve fail-closed flush stage execution contracts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "config/flush-stage-contracts.yml"
FULL_CHAIN = ROOT / ".github/workflows/full-chain-flush.yml"
LIFECYCLE = ROOT / ".github/workflows/flush-lifecycle.yml"
ALLOWED_SAFETY = {"dry-run", "read-only", "orchestration", "unsupported"}


def fail(message: str) -> "None":
    print(f"[flush-contract] {message}", file=sys.stderr)
    raise SystemExit(1)


def load_contract(path: Path) -> dict:
    try:
        data = yaml.safe_load(path.read_text())
    except (OSError, yaml.YAMLError) as exc:
        fail(f"cannot load {path}: {exc}")
    if not isinstance(data, dict) or data.get("version") != 1:
        fail("contract must be a mapping with version: 1")
    contracts = data.get("contracts")
    if not isinstance(contracts, dict) or not contracts:
        fail("contracts must be a non-empty mapping")
    return data


def dispatched_workflows(path: Path) -> set[str]:
    text = path.read_text()
    return set(
        re.findall(
            r"(?:flush-stage-dispatch|dispatch-and-wait)\.sh\s+([A-Za-z0-9_.-]+)\s+[0-9]+",
            text,
        )
    )


def validate(data: dict) -> None:
    contracts = data["contracts"]
    expected = dispatched_workflows(FULL_CHAIN) | dispatched_workflows(LIFECYCLE)
    missing = sorted(expected - contracts.keys())
    if missing:
        fail(f"missing contracts for: {', '.join(missing)}")

    errors: list[str] = []
    for workflow, contract in contracts.items():
        if not isinstance(contract, dict):
            errors.append(f"{workflow}: contract must be a mapping")
            continue
        repository = contract.get("repository", "current")
        if not isinstance(repository, str) or not repository:
            errors.append(f"{workflow}: repository must be a non-empty string")
        target_workflow = contract.get("workflow", workflow)
        if not isinstance(target_workflow, str) or not target_workflow:
            errors.append(f"{workflow}: workflow must be a non-empty string")
        capacity_slots = contract.get("capacity_slots", 1)
        if not isinstance(capacity_slots, int) or isinstance(capacity_slots, bool) or capacity_slots < 1:
            errors.append(f"{workflow}: capacity_slots must be a positive integer")
        for key in ("inputs", "live_inputs"):
            if key in contract and not isinstance(contract[key], dict):
                errors.append(f"{workflow}: {key} must be a mapping")
        rehearsal = contract.get("rehearsal")
        if not isinstance(rehearsal, dict):
            errors.append(f"{workflow}: rehearsal must be a mapping")
            continue
        safety = rehearsal.get("safety")
        if safety not in ALLOWED_SAFETY:
            errors.append(f"{workflow}: invalid rehearsal safety {safety!r}")
        inputs = rehearsal.get("inputs", {})
        if not isinstance(inputs, dict):
            errors.append(f"{workflow}: rehearsal.inputs must be a mapping")
        if safety == "dry-run" and inputs.get("dry_run") not in (True, "true"):
            errors.append(f"{workflow}: dry-run safety must force dry_run=true")
        if safety == "unsupported" and not rehearsal.get("reason"):
            errors.append(f"{workflow}: unsupported rehearsal needs a reason")
        if repository == "current":
            workflow_path = ROOT / ".github/workflows" / workflow
            if not workflow_path.is_file():
                errors.append(f"{workflow}: local workflow file does not exist")
                continue
            try:
                workflow_data = yaml.safe_load(workflow_path.read_text())
            except yaml.YAMLError as exc:
                errors.append(f"{workflow}: cannot parse workflow YAML: {exc}")
                continue
            triggers = workflow_data.get(True, {}) if isinstance(workflow_data, dict) else {}
            dispatch = triggers.get("workflow_dispatch") if isinstance(triggers, dict) else None
            declared = dispatch.get("inputs", {}) if isinstance(dispatch, dict) else {}
            supplied_keys = set(contract.get("inputs", {}))
            supplied_keys.update(contract.get("live_inputs", {}))
            supplied_keys.update(inputs)
            unknown = sorted(supplied_keys - set(declared or {}))
            if unknown:
                errors.append(
                    f"{workflow}: contract supplies undeclared inputs: {', '.join(unknown)}"
                )
    if errors:
        fail("invalid contract:\n  " + "\n  ".join(errors))
    print(f"Validated {len(contracts)} flush stage contracts", file=sys.stderr)


def resolve(data: dict, args: argparse.Namespace) -> None:
    contracts = data["contracts"]
    contract = contracts.get(args.workflow)
    if not isinstance(contract, dict):
        fail(f"no contract for {args.workflow}")
    try:
        supplied = json.loads(args.live_inputs)
    except json.JSONDecodeError as exc:
        fail(f"live inputs are not valid JSON: {exc}")
    if not isinstance(supplied, dict):
        fail("live inputs must be a JSON object")

    repository = contract.get("repository", "current")
    if repository == "current":
        repository = args.current_repository
    if not repository:
        fail(f"cannot resolve repository for {args.workflow}")

    inputs = dict(supplied)
    inputs.update(contract.get("inputs", {}))
    if args.mode == "live":
        inputs.update(contract.get("live_inputs", {}))
    else:
        rehearsal = contract["rehearsal"]
        if rehearsal["safety"] == "unsupported":
            fail(f"rehearsal refuses {args.workflow}: {rehearsal['reason']}")
        inputs.update(rehearsal.get("inputs", {}))

    target_workflow = contract.get("workflow", args.workflow)
    capacity_slots = contract.get("capacity_slots", 1)
    print(
        json.dumps(
            {
                "repository": repository,
                "workflow": target_workflow,
                "inputs": inputs,
                "capacity_slots": capacity_slots,
            },
            separators=(",", ":"),
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--resolve", dest="workflow")
    parser.add_argument("--mode", choices=("live", "rehearsal"))
    parser.add_argument("--live-inputs", default="{}")
    parser.add_argument("--current-repository", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    data = load_contract(args.contract)
    validate(data)
    if args.workflow:
        if not args.mode:
            fail("--mode is required with --resolve")
        resolve(data, args)


if __name__ == "__main__":
    main()
