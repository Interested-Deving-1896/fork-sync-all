#!/usr/bin/env python3
"""Read-only origin registry auditor for fork-sync-all.

Audits provenance.yml and origins.md references. It reports availability and
metadata findings and emits repair suggestions; it never modifies upstreams.
"""
from __future__ import annotations
import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "dep-graph" / "provenance.yml"
ORIGINS_MD = ROOT / "dep-graph" / "origins.md"

def load_influences(path: Path = PROVENANCE):
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("PyYAML is required (pip install pyyaml)") from exc
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    rows = data.get("influences", [])
    if not isinstance(rows, list):
        raise ValueError("provenance.yml: 'influences' must be a list")
    return rows

def normalize(row):
    source = str(row.get("source", "")).strip()
    url = str(row.get("url", "")).strip()
    relationship = str(row.get("relationship", "")).strip()
    issues = []
    if not source or "/" not in source:
        issues.append("invalid-or-missing-source")
    if not url.startswith(("https://github.com/", "https://gitlab.com/")):
        issues.append("unsupported-or-missing-url")
    if relationship not in {"fork", "extracted-logic", "inspired-by", "reference",
                            "schema-adopted", "pattern-adopted"}:
        issues.append("invalid-or-missing-relationship")
    return {"source": source, "url": url, "relationship": relationship,
            "what": str(row.get("what", "")).strip(),
            "artifact": str(row.get("artifact", "")).strip(),
            "notes": str(row.get("notes", "")).strip(), "registry_issues": issues}

def check_url(url, timeout=8):
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "fork-sync-all-origin-audit/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return {"status": "reachable", "http_status": response.status,
                    "final_url": response.geturl()}
    except urllib.error.HTTPError as exc:
        return {"status": "http-error", "http_status": exc.code, "detail": str(exc)}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {"status": "unverified", "detail": str(exc)}

def audit(rows, online=False):
    results = []
    for raw in rows:
        item = normalize(raw)
        if online and item["url"]:
            item["remote"] = check_url(item["url"])
            if item["remote"]["status"] != "reachable":
                item["repair_suggestion"] = "Verify canonical URL; check rename, archive, deletion, or network/rate-limit before updating provenance."
        else:
            item["remote"] = {"status": "not-checked"}
        results.append(item)
    return {"schema_version": 1, "mode": "online-read-only" if online else "registry-only",
            "origin_count": len(results),
            "invalid_registry_entries": sum(bool(x["registry_issues"]) for x in results),
            "unreachable_or_unverified": sum(x["remote"]["status"] not in ("reachable", "not-checked") for x in results),
            "origins": results}

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--online", action="store_true", help="Check public origin URLs (read-only; may be rate limited)")
    p.add_argument("--output", help="Write JSON report to this path instead of stdout")
    p.add_argument("--fail-on-findings", action="store_true", help="Exit 1 if registry findings or remote failures exist")
    args = p.parse_args(argv)
    try:
        report = audit(load_influences(), online=args.online)
    rendered = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            Path(args.output).write_text(rendered, encoding="utf-8")
        else:
            sys.stdout.write(rendered)
    except (RuntimeError, ValueError, OSError) as exc:
        print(f"origin audit error: {exc}", file=sys.stderr)
        return 2
    if args.fail_on_findings and (report["invalid_registry_entries"] or report["unreachable_or_unverified"]):
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
