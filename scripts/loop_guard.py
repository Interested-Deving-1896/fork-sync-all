#!/usr/bin/env python3
"""Provider-neutral, observe-only repetition detector for FSA operations.

The ledger stores metadata and SHA-256 fingerprints only; callers must not pass
credentials or sensitive payloads. This first adapter detects repeated
operations that show no progress. It never blocks, retries, cancels, or writes
to external services.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DEFAULT_WINDOW_SECONDS = 900
DEFAULT_THRESHOLD = 3
DEFAULT_MAX_EVENTS = 5000


def _canonical_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _load_events(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as stream:
        for line in stream:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict) and item.get("schema_version") == SCHEMA_VERSION:
                events.append(item)
    return events


def record_operation(
    ledger: Path,
    *,
    engine: str,
    action: str,
    target: str,
    request_fingerprint: str,
    progress: str = "",
    provider: str = "agnostic",
    repository: str = "",
    actor: str = "",
    window_seconds: int = DEFAULT_WINDOW_SECONDS,
    threshold: int = DEFAULT_THRESHOLD,
    max_events: int = DEFAULT_MAX_EVENTS,
    now: float | None = None,
) -> dict[str, Any]:
    """Append an event and report repeated identical work with unchanged progress."""
    if not all((engine, action, target, request_fingerprint)):
        raise ValueError("engine, action, target, and request_fingerprint are required")
    if window_seconds < 1 or threshold < 2 or max_events < 1:
        raise ValueError("window_seconds/max_events must be positive and threshold >= 2")

    timestamp = time.time() if now is None else now
    identity = {
        "engine": engine,
        "provider": provider,
        "action": action,
        "target": target,
        "request_fingerprint": request_fingerprint,
        "repository": repository,
    }
    operation_hash = _canonical_hash(identity)
    progress_hash = _canonical_hash(progress)
    event = {
        "schema_version": SCHEMA_VERSION,
        "operation_id": str(uuid.uuid4()),
        "timestamp": timestamp,
        **identity,
        "actor": actor,
        "operation_fingerprint": operation_hash,
        "progress_fingerprint": progress_hash,
    }

    ledger.parent.mkdir(parents=True, exist_ok=True)
    lock_path = ledger.with_suffix(ledger.suffix + ".lock")
    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        events = _load_events(ledger)
        recent = [
            item for item in events
            if timestamp - float(item.get("timestamp", 0)) <= window_seconds
            and timestamp >= float(item.get("timestamp", 0))
            and item.get("operation_fingerprint") == operation_hash
            and item.get("progress_fingerprint") == progress_hash
        ]
        count = len(recent) + 1
        event["repeat_count"] = count
        event["suspected_loop"] = count >= threshold
        event["confidence"] = "high" if count >= threshold + 1 else ("medium" if count >= threshold else "low")
        events.append(event)
        events = events[-max_events:]

        fd, temporary_name = tempfile.mkstemp(prefix=ledger.name + ".", dir=str(ledger.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                for item in events:
                    output.write(json.dumps(item, sort_keys=True) + "\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_name, ledger)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    return {
        "schema_version": SCHEMA_VERSION,
        "operation_id": event["operation_id"],
        "operation_fingerprint": operation_hash,
        "repeat_count": count,
        "threshold": threshold,
        "window_seconds": window_seconds,
        "suspected_loop": event["suspected_loop"],
        "confidence": event["confidence"],
        "mode": "observe-only",
        "action_taken": "recorded",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", default=os.environ.get("FSA_LOOP_LEDGER", ".fsa/loop-events.jsonl"))
    parser.add_argument("--engine", required=True)
    parser.add_argument("--action", required=True)
    parser.add_argument("--target", required=True, help="Normalized resource identity; do not include secrets")
    parser.add_argument("--request-fingerprint", required=True, help="Caller-provided non-secret request identity")
    parser.add_argument("--progress", default="", help="Cursor, page token, state version, or other progress marker")
    parser.add_argument("--provider", default="agnostic")
    parser.add_argument("--repository", default="")
    parser.add_argument("--actor", default="")
    parser.add_argument("--window-seconds", type=int, default=DEFAULT_WINDOW_SECONDS)
    parser.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    parser.add_argument("--max-events", type=int, default=DEFAULT_MAX_EVENTS)
    args = parser.parse_args()

    result = record_operation(
        Path(args.ledger), engine=args.engine, action=args.action, target=args.target,
        request_fingerprint=args.request_fingerprint, progress=args.progress,
        provider=args.provider, repository=args.repository, actor=args.actor,
        window_seconds=args.window_seconds, threshold=args.threshold, max_events=args.max_events,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
