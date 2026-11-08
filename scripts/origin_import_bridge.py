#!/usr/bin/env python3
"""Read-only consistency bridge between origin provenance and imported repos."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parents[1]
IMPORTS_DEFAULT = ROOT / "registered-imports.json"
PROVENANCE_DEFAULT = ROOT / "dep-graph" / "provenance.yml"


def canonical_source_url(value: object) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = urlsplit(value.strip())
        if (parsed.scheme != "https" or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.port not in (None, 443)
                or parsed.query or parsed.fragment):
            return None
        path = parsed.path.rstrip("/")
        if path.endswith(".git"):
            path = path[:-4]
        parts = [part for part in path.split("/") if part]
        if len(parts) != 2 or any(part in {".", ".."} for part in parts):
            return None
        return urlunsplit(("https", parsed.hostname.lower(), "/" + "/".join(parts), "", ""))
    except (ValueError, AttributeError):
        return None


def load_imports(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError("registered-imports.json must contain a JSON array")
    return data


def load_origins(path: Path) -> list[dict]:
    try:
        import yaml
    except ImportError as exc:
        raise RuntimeError("PyYAML is required to read dep-graph/provenance.yml") from exc
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict) or not isinstance(data.get("influences", []), list):
        raise ValueError("provenance.yml must contain an influences array")
    return data.get("influences", [])


def audit(imports: list[dict], origins: list[dict]) -> dict:
    import_index: dict[str, list[dict]] = {}
    origin_index: dict[str, list[dict]] = {}
    invalid_imports, invalid_origins = [], []
    for row in imports:
        if not isinstance(row, dict):
            invalid_imports.append({"reason": "invalid-row"})
            continue
        key = canonical_source_url(row.get("source_url"))
        if key is None:
            invalid_imports.append({"target_name": row.get("target_name"), "reason": "invalid-source-url"})
            continue
        import_index.setdefault(key, []).append(row)
    for row in origins:
        if not isinstance(row, dict):
            invalid_origins.append({"reason": "invalid-row"})
            continue
        key = canonical_source_url(row.get("url"))
        if key is None:
            invalid_origins.append({"source": row.get("source"), "reason": "invalid-source-url"})
            continue
        origin_index.setdefault(key, []).append(row)

    linked, import_only, origin_only = [], [], []
    for key in sorted(set(import_index) | set(origin_index)):
        imported, provenance = import_index.get(key, []), origin_index.get(key, [])
        if imported and provenance:
            linked.append({"source_url": key,
                "targets": sorted({str(row.get("target_name", "")) for row in imported}),
                "origin_sources": sorted({str(row.get("source", "")) for row in provenance}),
                "status": "linked"})
        elif imported:
            import_only.append({"source_url": key,
                "targets": sorted({str(row.get("target_name", "")) for row in imported}),
                "status": "import-without-origin-provenance"})
        else:
            origin_only.append({"source_url": key,
                "origin_sources": sorted({str(row.get("source", "")) for row in provenance}),
                "relationships": sorted({str(row.get("relationship", "")) for row in provenance}),
                "status": "origin-without-import-registration"})

    duplicate_import_urls = sorted(k for k, v in import_index.items() if len(v) > 1)
    duplicate_origin_urls = sorted(k for k, v in origin_index.items() if len(v) > 1)
    counts = {
        "linked": len(linked), "import_without_origin": len(import_only),
        "origin_without_import": len(origin_only),
        "invalid_import_rows": len(invalid_imports), "invalid_origin_rows": len(invalid_origins),
        "duplicate_import_urls": len(duplicate_import_urls),
        "duplicate_origin_urls": len(duplicate_origin_urls)
    }
    return {"schema_version": 1, "mode": "read-only", "counts": counts,
        "linked": linked, "import_without_origin": import_only, "origin_without_import": origin_only,
        "invalid_import_rows": invalid_imports, "invalid_origin_rows": invalid_origins,
        "duplicate_import_urls": duplicate_import_urls, "duplicate_origin_urls": duplicate_origin_urls,
        "policy": {"import_to_origins": "report-only; propose provenance changes for review",
            "origins_to_import": "report-only; attribution alone never authorizes import",
            "registry_writes": False, "repository_creation": False,
            "git_push": False, "workflow_dispatch": False}}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--imports", type=Path, default=IMPORTS_DEFAULT)
    parser.add_argument("--provenance", type=Path, default=PROVENANCE_DEFAULT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fail-on-findings", action="store_true")
    args = parser.parse_args(argv)
    try:
        report = audit(load_imports(args.imports), load_origins(args.provenance))
    except (OSError, json.JSONDecodeError, ValueError, RuntimeError) as exc:
        print(f"origin/import bridge error: {exc}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 1 if args.fail_on_findings and any(report["counts"].values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
