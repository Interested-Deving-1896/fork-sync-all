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
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
PROVENANCE = ROOT / "dep-graph" / "provenance.yml"
ORIGINS_MD = ROOT / "dep-graph" / "origins.md"
ALLOWED_HOSTS = {"github.com", "gitlab.com"}
RELATIONSHIPS = {"fork", "extracted-logic", "inspired-by", "reference",
                  "schema-adopted", "pattern-adopted"}


def load_influences(path: Path = PROVENANCE):
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("PyYAML is required (pip install pyyaml)") from exc
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise ValueError("provenance.yml: root must be a mapping")
    rows = data.get("influences", [])
    if not isinstance(rows, list):
        raise ValueError("provenance.yml: 'influences' must be a list")
    return rows


def canonical_repo_url(value):
    """Accept only canonical HTTPS GitHub/GitLab owner/repository URLs."""
    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value.strip())
        if (parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS
                or parsed.username is not None or parsed.password is not None
                or parsed.port not in (None, 443)
                or parsed.query or parsed.fragment):
            return False
        parts = parsed.path.strip("/").split("/")
        if len(parts) != 2 or any(not part or part in {".", ".."} for part in parts):
            return False
        if any(c in parts[0] + parts[1] for c in "\\"):
            return False
        return True
    except (ValueError, AttributeError):
        return False


def normalize(row):
    if not isinstance(row, dict):
        return {"source": "", "url": "", "relationship": "", "what": "",
                "artifact": "", "notes": "",
                "registry_issues": ["invalid-row-type"]}
    source = str(row.get("source", "")).strip()
    url = str(row.get("url", "")).strip()
    relationship = str(row.get("relationship", "")).strip()
    issues = []
    if not source or not re.fullmatch(r"[^/\s]+/[^/\s]+", source):
        issues.append("invalid-or-missing-source")
    if not canonical_repo_url(url):
        issues.append("unsupported-or-noncanonical-url")
    if relationship not in RELATIONSHIPS:
        issues.append("invalid-or-missing-relationship")
    return {"source": source, "url": url, "relationship": relationship,
            "what": str(row.get("what", "")).strip(),
            "artifact": str(row.get("artifact", "")).strip(),
            "notes": str(row.get("notes", "")).strip(),
            "registry_issues": issues}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_url(url, timeout=8):
    if not canonical_repo_url(url):
        return {"status": "invalid-url", "detail": "URL failed canonical HTTPS repository validation"}
    req = urllib.request.Request(url, method="GET",
                                headers={"User-Agent": "fork-sync-all-origin-audit/1.0"})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as response:
            return {"status": "reachable", "http_status": response.status,
                    "final_url": response.geturl()}
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            return {"status": "redirect-not-followed", "http_status": exc.code,
                    "detail": "Redirect deliberately not followed; review canonical URL manually"}
        return {"status": "http-error", "http_status": exc.code, "detail": str(exc)}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return {"status": "unverified", "detail": str(exc)}


def audit(rows, online=False):
    results = []
    for raw in rows:
        item = normalize(raw)
        if online and item["url"] and canonical_repo_url(item["url"]):
            item["remote"] = check_url(item["url"])
            if item["remote"]["status"] != "reachable":
                item["repair_suggestion"] = (
                    "Review canonical URL manually; redirects are never followed. "
                    "Distinguish rename/archive/deletion from network or rate-limit failures.")
        else:
            item["remote"] = {"status": "not-checked"}
        results.append(item)
    return {"schema_version": 1, "mode": "online-read-only" if online else "registry-only",
            "origin_count": len(results),
            "invalid_registry_entries": sum(bool(x["registry_issues"]) for x in results),
            "unreachable_or_unverified": sum(x["remote"]["status"] not in
                                           ("reachable", "not-checked") for x in results),
            "origins": results}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--online", action="store_true",
                   help="Check public origin URLs (read-only; may be rate limited)")
    p.add_argument("--output", help="Write JSON report to this path instead of stdout")
    p.add_argument("--fail-on-findings", action="store_true",
                   help="Exit 1 if registry findings or remote failures exist")
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
    if args.fail_on_findings and (report["invalid_registry_entries"] or
                                 report["unreachable_or_unverified"]):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
