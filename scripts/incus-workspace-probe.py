#!/usr/bin/env python3
"""Read-only Incus capability probe for Fork-Sync-All.

This probe never initializes Incus, creates/deletes instances, changes profiles,
mounts paths, or edits host configuration. A missing/failed observation is
reported as unknown/unavailable, never as healthy.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from typing import Any, Callable


def _run(command: list[str], timeout: int = 5) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            command, check=False, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return {"status": "unknown", "error": "timeout"}
    except OSError as exc:
        return {"status": "unknown", "error": str(exc)}
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()[:500]
        return {
            "status": "unavailable",
            "exit_code": completed.returncode,
            "error": detail or "command failed without diagnostic output",
        }
    return {"status": "available", "output": completed.stdout.strip()[:2000]}


def probe(
    which: Callable[[str], str | None] = shutil.which,
    run: Callable[[list[str], int], dict[str, Any]] = _run,
) -> dict[str, Any]:
    """Collect bounded, read-only observations; injectable dependencies enable offline tests."""
    executable = which("incus")
    result: dict[str, Any] = {
        "schema_version": 1,
        "backend": "incus",
        "probe_mode": "read_only",
        "status": "unknown",
        "capabilities": {
            "create_workspace": "unknown",
            "inspect_workspace": "unknown",
            "exec_workspace": "unknown",
            "interactive_shell": "unknown",
            "snapshot": "unknown",
            "network_policy": "unknown",
            "resource_limits": "unknown",
            "isolated_vm": "unknown",
        },
        "observations": {},
        "safety": {
            "mutations_attempted": False,
            "host_configuration_changed": False,
            "resources_created_or_deleted": False,
        },
    }
    if not executable:
        result["status"] = "unavailable"
        result["observations"]["client"] = {
            "status": "unavailable",
            "error": "incus executable not found on PATH",
        }
        return result

    result["observations"]["client"] = {"status": "available", "path": executable}
    result["observations"]["version"] = run([executable, "version"], 5)
    # info is observational; it does not initialize or modify the daemon.
    result["observations"]["daemon"] = run([executable, "info", "--format=json"], 5)
    daemon_status = result["observations"]["daemon"].get("status")
    version_status = result["observations"]["version"].get("status")
    if daemon_status == "available" and version_status == "available":
        result["status"] = "available"
        # A working daemon is not proof of isolation or policy support.
        result["capabilities"]["inspect_workspace"] = "available"
        result["capabilities"]["create_workspace"] = "requires_policy_review"
        result["capabilities"]["exec_workspace"] = "requires_policy_review"
    elif daemon_status == "unavailable":
        result["status"] = "unavailable"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit JSON (default)")
    parser.parse_args()
    print(json.dumps(probe(), sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
