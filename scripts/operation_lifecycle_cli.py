"""JSON CLI for the offline operation lifecycle evaluators.

Input is supplied as a JSON file or stdin. Results are written to stdout.
This interface is intentionally offline and cannot execute or authorize work.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    from . import operation_lifecycle
except ImportError:  # direct script execution
    import operation_lifecycle


def evaluate(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise operation_lifecycle.ContractError("request must be a JSON object")
    mode = payload.get("mode")
    if mode == "preflight":
        return operation_lifecycle.evaluate_preflight(
            payload.get("operation"), payload.get("evidence"),
            payload.get("blockers"), payload.get("warnings"),
        )
    if mode == "postflight":
        return operation_lifecycle.evaluate_postflight(
            payload.get("operation"), payload.get("preflight"),
            payload.get("evidence"), payload.get("criteria_results"),
            payload.get("deviations"),
        )
    raise operation_lifecycle.ContractError("mode must be 'preflight' or 'postflight'")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="JSON request file; defaults to stdin")
    args = parser.parse_args(argv)
    try:
        raw = args.input.read_text(encoding="utf-8") if args.input else sys.stdin.read()
        request = json.loads(raw)
        result = evaluate(request)
    except (OSError, json.JSONDecodeError, operation_lifecycle.ContractError) as exc:
        print(json.dumps({"error": str(exc), "status": "invalid_request"}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
