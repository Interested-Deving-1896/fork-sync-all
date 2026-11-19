#!/usr/bin/env python3
"""Audit README content parity across enabled deployments on supported forges."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "scripts" / "collect-forge-readmes.sh"


def load_registry(path: Path) -> list[dict[str, Any]]:
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("PyYAML is required to read the deployment registry") from exc
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    deployments = data.get("deployments") or []
    if not isinstance(deployments, list):
        raise ValueError("deployment registry must contain a deployments list")
    return [item for item in deployments if item.get("enabled", True)]


def load_exceptions(path: Path | None) -> set[str]:
    if path is None:
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    return set((data.get("exceptions") or {}).keys())


def collect(deployment: dict[str, Any]) -> dict[str, Any]:
    platform = deployment["platform"]
    namespace = deployment.get("org") or deployment.get("group_path")
    if not namespace:
        raise ValueError(f"deployment {deployment['id']} has no namespace")
    host = deployment.get("host") or ""
    include_nested = "true" if platform == "gitlab" else "false"
    result = subprocess.run(
        [
            "bash",
            str(COLLECTOR),
            platform,
            host,
            namespace,
            include_nested,
        ],
        cwd=ROOT,
        env=os.environ.copy(),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        message = result.stderr.strip().splitlines()
        raise RuntimeError(message[-1] if message else f"collector exited {result.returncode}")
    projects: dict[str, list[dict[str, Any]]] = {}
    for line in result.stdout.splitlines():
        coordinate, state, digest, encoded = (line.split("\t") + ["", "", ""])[:4]
        name = coordinate.rsplit("/", 1)[-1]
        content = base64.b64decode(encoded).decode("utf-8", errors="replace") if encoded else None
        projects.setdefault(name, []).append(
            {
                "coordinate": coordinate,
                "readme": state == "present",
                "sha256": digest or None,
                "content": content,
            }
        )
    return {
        "id": deployment["id"],
        "platform": platform,
        "namespace": namespace,
        "projects": projects,
    }


def compare_snapshots(
    snapshots: list[dict[str, Any]], source_id: str, exceptions: set[str]
) -> dict[str, Any]:
    by_id = {item["id"]: item for item in snapshots}
    if source_id not in by_id:
        raise ValueError(f"source deployment {source_id!r} was not collected")
    source = by_id[source_id]
    findings: list[dict[str, str]] = []
    surfaces: list[dict[str, Any]] = []
    for snapshot in snapshots:
        duplicate_names = sorted(
            name for name, entries in snapshot["projects"].items() if len(entries) > 1
        )
        for name in duplicate_names:
            findings.append(
                {
                    "surface": snapshot["id"],
                    "project": name,
                    "finding": "ambiguous project name across nested namespaces",
                }
            )
        compared = 0
        if snapshot["id"] != source_id:
            for name, entries in sorted(snapshot["projects"].items()):
                if name in exceptions or len(entries) != 1:
                    continue
                source_entries = source["projects"].get(name, [])
                if len(source_entries) != 1:
                    findings.append(
                        {
                            "surface": snapshot["id"],
                            "project": name,
                            "finding": "canonical source project is missing or ambiguous",
                        }
                    )
                    continue
                compared += 1
                target_entry, source_entry = entries[0], source_entries[0]
                if not source_entry["readme"]:
                    findings.append(
                        {
                            "surface": snapshot["id"],
                            "project": name,
                            "finding": "canonical README.md is missing",
                        }
                    )
                elif not target_entry["readme"]:
                    findings.append(
                        {
                            "surface": snapshot["id"],
                            "project": name,
                            "finding": "downstream README.md is missing",
                        }
                    )
                elif source_entry["sha256"] != target_entry["sha256"]:
                    findings.append(
                        {
                            "surface": snapshot["id"],
                            "project": name,
                            "finding": "README content differs from canonical source",
                        }
                    )
        surfaces.append(
            {
                "id": snapshot["id"],
                "platform": snapshot["platform"],
                "namespace": snapshot["namespace"],
                "projects": sum(len(value) for value in snapshot["projects"].values()),
                "compared": compared,
            }
        )
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_deployment": source_id,
        "healthy": not findings,
        "surfaces": surfaces,
        "findings": findings,
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Forge README parity audit",
        "",
        f"**Overall:** {'Healthy' if report['healthy'] else 'Attention required'}",
        "",
        f"Generated: `{report['generated_at']}`",
        "",
        "| Deployment | Platform | Namespace | Projects | Compared |",
        "|---|---|---|---:|---:|",
    ]
    lines.extend(
        f"| {item['id']} | {item['platform']} | {item['namespace']} | "
        f"{item['projects']} | {item['compared']} |"
        for item in report["surfaces"]
    )
    lines.extend(["", f"**Findings:** {len(report['findings'])}", ""])
    if report["findings"]:
        lines.extend(
            f"- **{item['surface']} / {item['project']}** — {item['finding']}"
            for item in report["findings"]
        )
    else:
        lines.append("No README content drift was found on observed downstream projects.")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry", type=Path, default=ROOT / "config" / "fsa-deployments.yml"
    )
    parser.add_argument("--source-deployment", default="source")
    parser.add_argument(
        "--exceptions", type=Path, default=ROOT / "config" / "mirror-readme-baseline.json"
    )
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    parser.add_argument("--fail-on-findings", action="store_true")
    args = parser.parse_args()
    try:
        deployments = load_registry(args.registry)
        snapshots = [collect(item) for item in deployments]
        report = compare_snapshots(
            snapshots, args.source_deployment, load_exceptions(args.exceptions)
        )
        args.output_json.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        rendered = render_markdown(report)
        args.output_markdown.write_text(rendered, encoding="utf-8")
        print(rendered)
        return 1 if args.fail_on_findings and not report["healthy"] else 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"audit-forge-readme-parity: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
