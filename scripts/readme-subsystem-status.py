#!/usr/bin/env python3
"""Audit README subsystem drift and documentation-site availability."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def run(*args: str) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def clone_project(project: dict[str, Any], destination: Path) -> str:
    run(
        "git",
        "clone",
        "--quiet",
        "--depth",
        "1",
        "--branch",
        project["branch"],
        project["clone_url"],
        str(destination),
    )
    return run("git", "-C", str(destination), "rev-parse", "HEAD")


def page_status(url: str) -> tuple[bool, int | None, str]:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "fork-sync-all-readme-subsystem-status/1.0"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            code = response.getcode()
            return 200 <= code < 400, code, ""
    except urllib.error.HTTPError as exc:
        return False, exc.code, str(exc)
    except (urllib.error.URLError, TimeoutError) as exc:
        return False, None, str(exc)


def compare_file(source: Path, destination: Path, label: str, drift: list[str]) -> None:
    if not source.is_file():
        drift.append(f"{label}: source missing ({source})")
    elif not destination.is_file():
        drift.append(f"{label}: destination missing ({destination})")
    elif source.read_bytes() != destination.read_bytes():
        drift.append(f"{label}: content differs")


def compare_profile_chain(
    contract: dict[str, Any], checkouts: dict[str, Path], drift: list[str]
) -> None:
    source_key = "interested-deving-1896"
    source_root = checkouts.get(source_key)
    if source_root is None:
        drift.append("profile-chain: Interested-Deving-1896 source is unavailable")
        return
    targets_path = source_root / "config" / "profile-targets.json"
    if not targets_path.is_file():
        drift.append("profile-chain: config/profile-targets.json is missing")
        return
    targets = load_json(targets_path)
    repository_keys = {
        f"{project['namespace']}/{project['project']}": key
        for key, project in contract["projects"].items()
    }

    def destination_root(repository: str) -> Path | None:
        key = repository_keys.get(repository)
        return checkouts.get(key) if key else None

    for profile_key, profile in targets.get("profiles", {}).items():
        source = source_root / profile["source"]
        for destination in profile.get("destinations", []):
            target_root = destination_root(destination["repository"])
            if target_root is not None:
                compare_file(
                    source,
                    target_root / destination["path"],
                    f"{profile_key}:README:{destination['repository']}",
                    drift,
                )
        for kind in ("policy", "lore"):
            source_name = profile.get(f"{kind}_source")
            destination = profile.get(f"{kind}_destination")
            if not source_name or not destination:
                continue
            target_root = destination_root(destination["repository"])
            if target_root is not None:
                compare_file(
                    source_root / source_name,
                    target_root / destination["path"],
                    f"{profile_key}:{kind}:{destination['repository']}",
                    drift,
                )
        payload = profile.get("repository_payload", {})
        payload_root = destination_root(payload.get("repository", ""))
        if payload_root is not None:
            for item in payload.get("files", []):
                compare_file(
                    source_root / item["source"],
                    payload_root / item["path"],
                    f"{profile_key}:payload:{item['path']}",
                    drift,
                )
            for item in payload.get("roots", []):
                source_directory = source_root / item["source"]
                for source_file in source_directory.rglob("*"):
                    if source_file.is_file():
                        relative = source_file.relative_to(source_directory)
                        compare_file(
                            source_file,
                            payload_root / item["path"] / relative,
                            f"{profile_key}:payload:{relative.as_posix()}",
                            drift,
                        )

    automation = targets.get("shared_automation", {})
    for destination in automation.get("destinations", []):
        target_root = destination_root(destination["repository"])
        if target_root is None:
            continue
        for source_name in automation.get("sources", []):
            compare_file(
                source_root / source_name,
                target_root / source_name,
                f"{destination['profile']}:automation:{source_name}",
                drift,
            )


def render_markdown(report: dict[str, Any]) -> str:
    state = "Healthy" if report["healthy"] else "Attention required"
    lines = [
        "# README subsystem status",
        "",
        f"**Overall:** {state}",
        "",
        f"Generated: `{report['generated_at']}`",
        "",
        "| Project | Revision | Repository | Pages |",
        "|---|---|---|---|",
    ]
    for project in report["projects"]:
        revision = project.get("revision", "unavailable")[:12]
        repository = "healthy" if project["repository_reachable"] else "failed"
        pages = project.get("pages") or {}
        if not pages:
            pages_text = "not configured"
        else:
            pages_text = f"HTTP {pages.get('status') or 'error'}"
        lines.append(
            f"| {project['id']} | `{revision}` | {repository} | {pages_text} |"
        )
    lines.extend(["", f"**Drift findings:** {len(report['drift'])}", ""])
    if report["drift"]:
        lines.extend(f"- {item}" for item in report["drift"])
    else:
        lines.append("No file drift detected across the declared ownership chain.")
    if report["errors"]:
        lines.extend(["", "## Monitor errors", ""])
        lines.extend(f"- {item}" for item in report["errors"])
    lines.append("")
    return "\n".join(lines)


def audit(contract_path: Path, canonical_root: Path) -> dict[str, Any]:
    contract = load_json(contract_path)
    canonical_key = contract["canonical_project"]
    projects: list[dict[str, Any]] = []
    drift: list[str] = []
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="readme-subsystem-status-") as directory:
        temporary = Path(directory)
        checkouts: dict[str, Path] = {canonical_key: canonical_root}
        for key, project in contract["projects"].items():
            row: dict[str, Any] = {
                "id": key,
                "repository_reachable": True,
                "revision": "",
            }
            try:
                if key == canonical_key:
                    row["revision"] = run(
                        "git", "-C", str(canonical_root), "rev-parse", "HEAD"
                    )
                else:
                    destination = temporary / key
                    row["revision"] = clone_project(project, destination)
                    checkouts[key] = destination
            except (OSError, subprocess.CalledProcessError) as exc:
                row["repository_reachable"] = False
                errors.append(f"{key}: repository clone failed: {exc}")
            pages_url = project.get("pages_url")
            if pages_url:
                okay, status, message = page_status(pages_url)
                row["pages"] = {"url": pages_url, "healthy": okay, "status": status}
                if not okay:
                    errors.append(f"{key}: Pages check failed: {message or status}")
            projects.append(row)

        source_root = checkouts.get("interested-deving-1896")
        if source_root is not None:
            for artifact in contract["artifacts"]:
                if (
                    artifact["owner"] != canonical_key
                    or artifact.get("delegated_to")
                ):
                    continue
                for destination in artifact["destinations"]:
                    if destination["project"] == "interested-deving-1896":
                        compare_file(
                            canonical_root / artifact["source"],
                            source_root / destination["path"],
                            f"engine:{artifact['id']}",
                            drift,
                        )
        else:
            drift.append("engine-chain: profile source is unavailable")
        compare_profile_chain(contract, checkouts, drift)

    unique_drift = sorted(set(drift))
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "healthy": not unique_drift and not errors,
        "projects": projects,
        "drift": unique_drift,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--contract", type=Path, default=ROOT / "config" / "readme-subsystem.json"
    )
    parser.add_argument("--canonical-root", type=Path, default=ROOT)
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    parser.add_argument("--fail-on-drift", action="store_true")
    args = parser.parse_args()
    try:
        report = audit(args.contract.resolve(), args.canonical_root.resolve())
        args.output_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_markdown.parent.mkdir(parents=True, exist_ok=True)
        args.output_json.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        args.output_markdown.write_text(render_markdown(report), encoding="utf-8")
        print(render_markdown(report))
        return 1 if args.fail_on_drift and not report["healthy"] else 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"readme-subsystem-status: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
