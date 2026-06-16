#!/usr/bin/env python3
"""
ona-mcp-server.py — AI-agent-agnostic Ona Projects MCP server

Exposes Ona project operations as MCP tools so any compatible agent
(Claude, Copilot, Cursor, etc.) can query and create environments
without knowing the Ona API shape.

Layer model:
  config/ona-projects.yml  ← source of truth (A)
  scripts/ona-projects.sh  ← operator / mutation layer (B)
  this file                ← agent interface / MCP server (C)

Run modes:
  # Devcontainer service (started by automations.yaml):
  python3 scripts/ona-mcp-server.py

  # Portable — any machine with Python 3.10+ and mcp installed:
  ONA_TOKEN=<token> python3 scripts/ona-mcp-server.py

  # stdio transport (for agents that speak MCP over stdin/stdout):
  python3 scripts/ona-mcp-server.py --stdio

Environment:
  ONA_TOKEN   Ona API token. Absent = read-only mode (no environment creation).
  ONA_API     Ona API base URL (default: https://app.ona.com/api/v1)
  CONFIG      Path to ona-projects.yml (default: config/ona-projects.yml)
  MCP_PORT    SSE server port (default: 8788)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import httpx
import yaml
from mcp.server.fastmcp import FastMCP

# ── Config ────────────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).parent.parent
CONFIG_PATH = Path(os.environ.get("CONFIG", REPO_ROOT / "config" / "ona-projects.yml"))
ONA_API = os.environ.get("ONA_API", "https://app.ona.com/api/v1")
ONA_TOKEN = os.environ.get("ONA_TOKEN", "")
MCP_PORT = int(os.environ.get("MCP_PORT", "8788"))

# ── Helpers ───────────────────────────────────────────────────────────────────

def _load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f) or {}


def _projects() -> dict[str, dict]:
    return _load_config().get("projects") or {}


def _ona_headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {ONA_TOKEN}",
        "Content-Type": "application/json",
    }


def _ona_get(path: str) -> dict:
    if not ONA_TOKEN:
        return {"error": "ONA_TOKEN not set — read-only mode"}
    try:
        r = httpx.get(f"{ONA_API}{path}", headers=_ona_headers(), timeout=15)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        return {"error": str(e)}


def _ona_post(path: str, body: dict) -> dict:
    if not ONA_TOKEN:
        return {"error": "ONA_TOKEN not set — cannot create resources"}
    try:
        r = httpx.post(f"{ONA_API}{path}", headers=_ona_headers(), json=body, timeout=30)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        return {"error": str(e)}


# ── MCP server ────────────────────────────────────────────────────────────────

mcp = FastMCP(
    name="ona-projects",
    instructions=(
        "Ona Projects MCP server for the Interested-Deving-1896 org chain. "
        "Use list_projects to discover available projects, get_project for details, "
        "create_environment to spin up a dev environment, and sync_projects to "
        "reconcile config/ona-projects.yml with the Ona API."
    ),
)


@mcp.tool()
def list_projects(tag: str = "") -> list[dict[str, Any]]:
    """List all Ona projects in the org chain.

    Args:
        tag: Optional tag to filter by (e.g. 'osp-bound', 'control-plane').
             Empty string returns all projects.

    Returns:
        List of project summaries with key, name, repo, project_id, tags.
    """
    projects = _projects()
    result = []
    for key, p in projects.items():
        tags = p.get("tags") or []
        if tag and tag not in tags:
            continue
        result.append({
            "key": key,
            "name": p.get("name") or key,
            "repo": p.get("repo", ""),
            "branch": p.get("branch", "main"),
            "project_id": p.get("project_id") or None,
            "synced": bool(p.get("project_id")),
            "tags": tags,
            "description": (p.get("description") or "").strip(),
        })
    return result


@mcp.tool()
def get_project(key: str) -> dict[str, Any]:
    """Get full details for a single project.

    Args:
        key: Project key from config/ona-projects.yml (e.g. 'fork-sync-all').

    Returns:
        Project config merged with live Ona API data if project_id is set.
    """
    projects = _projects()
    if key not in projects:
        return {"error": f"Unknown project key '{key}'. Use list_projects() to see available keys."}

    p = projects[key]
    result: dict[str, Any] = {
        "key": key,
        "name": p.get("name") or key,
        "repo": p.get("repo", ""),
        "branch": p.get("branch", "main"),
        "classes": p.get("classes") or [_load_config().get("default_class", "Regular")],
        "project_id": p.get("project_id") or None,
        "tags": p.get("tags") or [],
        "description": (p.get("description") or "").strip(),
    }

    # Enrich with live Ona data if we have a project_id and token
    pid = p.get("project_id")
    if pid and ONA_TOKEN:
        live = _ona_get(f"/projects/{pid}")
        if "error" not in live:
            result["ona"] = live

    return result


@mcp.tool()
def create_environment(key: str, environment_class: str = "") -> dict[str, Any]:
    """Create a new Ona environment for a project.

    The project must already be synced (have a project_id). If not, instruct
    the user to run sync_projects first or set ONA_TOKEN and re-sync.

    Args:
        key:               Project key (e.g. 'fork-sync-all').
        environment_class: Environment class to use (e.g. 'Regular', 'Large').
                           Defaults to the project's first configured class.

    Returns:
        Environment details including URL if creation succeeded, or an error dict.
    """
    projects = _projects()
    if key not in projects:
        return {"error": f"Unknown project key '{key}'."}

    p = projects[key]
    pid = p.get("project_id")
    if not pid:
        return {
            "error": (
                f"Project '{key}' has not been synced yet (no project_id). "
                "Run sync_projects() or set ONA_TOKEN and trigger the "
                "sync-ona-projects workflow."
            )
        }

    if not ONA_TOKEN:
        return {
            "error": "ONA_TOKEN not set — cannot create environments.",
            "hint": "Add ONA_TOKEN to your environment or GitHub Actions secrets.",
            "project_id": pid,
            "would_post": f"POST {ONA_API}/environments",
        }

    cfg = _load_config()
    classes = p.get("classes") or [cfg.get("default_class", "Regular")]
    chosen_class = environment_class if environment_class in classes else classes[0]

    body: dict[str, Any] = {"projectId": pid}
    if chosen_class:
        body["environmentClass"] = chosen_class

    result = _ona_post("/environments", body)
    if "error" in result:
        return result

    return {
        "key": key,
        "project_id": pid,
        "environment_class": chosen_class,
        "environment_id": result.get("id"),
        "url": result.get("url") or result.get("ideUrl"),
        "status": result.get("status", "creating"),
        "raw": result,
    }


@mcp.tool()
def sync_projects(dry_run: bool = True, project_key: str = "") -> dict[str, Any]:
    """Sync config/ona-projects.yml to the Ona API.

    Calls scripts/ona-projects.sh which creates or updates projects.
    Defaults to dry_run=True so agents cannot accidentally mutate state.

    Args:
        dry_run:     If True (default), report what would change without calling the API.
        project_key: Sync a single project only. Empty = sync all.

    Returns:
        Script stdout/stderr and exit code.
    """
    script = REPO_ROOT / "scripts" / "ona-projects.sh"
    if not script.exists():
        return {"error": f"Script not found: {script}"}

    cmd = ["bash", str(script)]
    if dry_run:
        cmd.append("--dry-run")
    if project_key:
        cmd += ["--project", project_key]

    env = os.environ.copy()
    if not ONA_TOKEN:
        env.pop("ONA_TOKEN", None)  # ensure dry-run path in script

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
            cwd=str(REPO_ROOT),
        )
        return {
            "exit_code": proc.returncode,
            "dry_run": dry_run,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "success": proc.returncode == 0,
        }
    except subprocess.TimeoutExpired:
        return {"error": "Script timed out after 120s"}
    except Exception as e:
        return {"error": str(e)}


@mcp.tool()
def get_config_summary() -> dict[str, Any]:
    """Return a summary of the ona-projects.yml configuration.

    Useful for agents that need to understand the org topology before
    deciding which project to use.

    Returns:
        ona_org, runner, default_class, project count, tag breakdown.
    """
    cfg = _load_config()
    projects = cfg.get("projects") or {}

    tag_counts: dict[str, int] = {}
    synced = 0
    for p in projects.values():
        if p.get("project_id"):
            synced += 1
        for t in (p.get("tags") or []):
            tag_counts[t] = tag_counts.get(t, 0) + 1

    return {
        "ona_org": cfg.get("ona_org") or "(not configured)",
        "runner": cfg.get("runner") or "(not configured)",
        "default_class": cfg.get("default_class", "Regular"),
        "total_projects": len(projects),
        "synced_projects": synced,
        "unsynced_projects": len(projects) - synced,
        "token_present": bool(ONA_TOKEN),
        "read_only": not bool(ONA_TOKEN),
        "tags": tag_counts,
        "config_path": str(CONFIG_PATH),
    }


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    stdio = "--stdio" in sys.argv

    if not ONA_TOKEN:
        print(
            "[ona-mcp-server] ONA_TOKEN not set — running in read-only mode.\n"
            "  create_environment and sync_projects (dry_run=False) will return errors.\n"
            "  Set ONA_TOKEN to enable full functionality.",
            file=sys.stderr,
        )

    if stdio:
        # stdio transport: agent speaks MCP over stdin/stdout (e.g. Claude Desktop)
        mcp.run(transport="stdio")
    else:
        # SSE transport: agent connects over HTTP (devcontainer service mode)
        print(
            f"[ona-mcp-server] Starting SSE server on port {MCP_PORT}",
            file=sys.stderr,
        )
        mcp.run(transport="sse", port=MCP_PORT)
