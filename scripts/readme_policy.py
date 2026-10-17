#!/usr/bin/env python3
"""Dependency-free README policy, rendering, accessibility, and maintenance checks."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


LINK_RE = re.compile(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)")
IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
HTML_IMAGE_RE = re.compile(r"<img\b([^>]*)>", re.IGNORECASE)
MARKER_RE = re.compile(
    r"<!-- README-AUTO:start:([a-z0-9_-]+) -->(.*?)"
    r"<!-- README-AUTO:end:\1 -->",
    re.DOTALL,
)
START_MARKER_RE = re.compile(r"<!-- README-AUTO:start:([a-z0-9_-]+) -->")
END_MARKER_RE = re.compile(r"<!-- README-AUTO:end:([a-z0-9_-]+) -->")
VAGUE_LINK_TEXT = {"click here", "here", "link", "more", "read more"}


@dataclass
class Finding:
    level: str
    code: str
    message: str
    line: int = 1


def load_policy(path: Path) -> dict[str, Any]:
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read policy {path}: {exc}") from exc
    if policy.get("schema_version") != 1:
        raise ValueError("README policy schema_version must be 1")
    for field in ("identity", "required_headings", "managed_blocks"):
        if field not in policy:
            raise ValueError(f"README policy requires {field}")
    return policy


def line_number(content: str, offset: int) -> int:
    return content.count("\n", 0, offset) + 1


def github_anchor(heading: str) -> str:
    value = heading.strip().casefold()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    value = re.sub(r"\s+", "-", value)
    return re.sub(r"-+", "-", value).strip("-")


def outside_fences(content: str) -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    marker: tuple[str, int] | None = None
    for number, line in enumerate(content.splitlines(), start=1):
        fence = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence:
            value = fence.group(1)
            if marker is None:
                marker = (value[0], len(value))
            elif value[0] == marker[0] and len(value) >= marker[1]:
                marker = None
            continue
        if marker is None:
            result.append((number, line))
    return result


def local_target(readme: Path, raw_target: str) -> tuple[Path, str] | None:
    target = raw_target.strip().strip("<>").split()[0]
    parsed = urllib.parse.urlsplit(target)
    if parsed.scheme or target.startswith("/"):
        return None
    path = urllib.parse.unquote(parsed.path)
    resolved = readme if not path else (readme.parent / path).resolve()
    return resolved, urllib.parse.unquote(parsed.fragment)


def add(
    findings: list[Finding], level: str, code: str, message: str, line: int = 1
) -> None:
    findings.append(Finding(level=level, code=code, message=message, line=line))


def check_managed_blocks(
    content: str, policy: dict[str, Any], findings: list[Finding]
) -> None:
    starts = START_MARKER_RE.findall(content)
    ends = END_MARKER_RE.findall(content)
    if sorted(starts) != sorted(ends):
        add(findings, "error", "managed-markers", "managed block markers are unbalanced")

    actual = {match.group(1): match.group(2) for match in MARKER_RE.finditer(content)}
    for name, expected_lines in policy.get("managed_blocks", {}).items():
        if name not in actual:
            add(findings, "error", "managed-block", f"missing managed block {name!r}")
            continue
        normalized = [line for line in actual[name].strip("\n").splitlines()]
        if normalized != expected_lines:
            match = re.search(
                rf"<!-- README-AUTO:start:{re.escape(name)} -->", content
            )
            add(
                findings,
                "error",
                "managed-drift",
                f"managed block {name!r} differs from repository policy",
                line_number(content, match.start()) if match else 1,
            )


def check_tables(lines: list[tuple[int, str]], findings: list[Finding]) -> None:
    table: list[tuple[int, str]] = []

    def flush() -> None:
        nonlocal table
        if len(table) < 2:
            table = []
            return
        counts = [len(re.split(r"(?<!\\)\|", row.strip().strip("|"))) for _, row in table]
        expected = counts[0]
        for (number, _), count in zip(table, counts):
            if count != expected:
                add(
                    findings,
                    "error",
                    "table-columns",
                    f"table row has {count} columns; expected {expected}",
                    number,
                )
        separator = table[1][1].strip().strip("|")
        if not all(
            re.fullmatch(r"\s*:?-{3,}:?\s*", cell)
            for cell in re.split(r"(?<!\\)\|", separator)
        ):
            add(
                findings,
                "error",
                "table-header",
                "table is missing a valid header separator row",
                table[1][0],
            )
        table = []

    for item in [*lines, (-1, "")]:
        if item[1].lstrip().startswith("|"):
            table.append(item)
        else:
            flush()


def check_external_links(urls: set[str], findings: list[Finding]) -> None:
    for url in sorted(urls)[:50]:
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": "README-policy-link-check/1.0",
                "Range": "bytes=0-1024",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=12) as response:
                if response.status >= 400:
                    raise urllib.error.HTTPError(
                        url, response.status, "link check", response.headers, None
                    )
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            add(
                findings,
                "warning",
                "external-link",
                f"external link could not be verified: {url} ({exc})",
            )


def quality(
    readme: Path,
    policy: dict[str, Any],
    check_external: bool,
) -> tuple[list[Finding], dict[str, Any]]:
    content = readme.read_text(encoding="utf-8")
    findings: list[Finding] = []
    visible_lines = outside_fences(content)
    visible = "\n".join(line for _, line in visible_lines)

    headings: list[tuple[int, int, str]] = []
    for number, line in visible_lines:
        match = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if match:
            headings.append((number, len(match.group(1)), match.group(2)))
    h1 = [heading for heading in headings if heading[1] == 1]
    if len(h1) != 1:
        add(findings, "error", "h1-count", f"expected one H1; found {len(h1)}")
    heading_names = {heading[2].casefold() for heading in headings}
    for required in policy.get("required_headings", []):
        if required.casefold() not in heading_names:
            add(findings, "error", "required-heading", f"missing heading: {required}")
    for previous, current in zip(headings, headings[1:]):
        if current[1] > previous[1] + 1:
            add(
                findings,
                "warning",
                "heading-jump",
                f"heading level jumps from H{previous[1]} to H{current[1]}",
                current[0],
            )

    identity = policy.get("identity", {})
    lowered = content.casefold()
    for required in identity.get("required", []):
        if required.casefold() not in lowered:
            add(findings, "error", "required-identity", f"missing identity: {required}")
    for forbidden in identity.get("forbidden", []):
        if forbidden.casefold() in lowered:
            add(findings, "error", "forbidden-identity", f"forbidden identity: {forbidden}")
    for badge in policy.get("required_badges", []):
        if badge not in content:
            add(findings, "error", "required-badge", f"missing required badge: {badge}")

    check_managed_blocks(content, policy, findings)

    fence_count = 0
    active: tuple[str, int] | None = None
    for number, line in enumerate(content.splitlines(), start=1):
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if not match:
            continue
        fence_count += 1
        marker = match.group(1)
        if active is None:
            active = (marker[0], len(marker))
        elif marker[0] == active[0] and len(marker) >= active[1]:
            active = None
    if active:
        add(findings, "error", "fenced-code", "unclosed fenced code block")

    external_urls: set[str] = set()
    anchors = {github_anchor(heading[2]) for heading in headings}
    for match in LINK_RE.finditer(visible):
        text, target = match.groups()
        target = target.strip().strip("<>").split()[0]
        number = line_number(visible, match.start())
        if text.strip().casefold() in VAGUE_LINK_TEXT:
            add(
                findings,
                "warning",
                "link-text",
                f"link text {text!r} is not descriptive",
                number,
            )
        if target.startswith(("https://", "http://")):
            external_urls.add(target)
            continue
        local = local_target(readme.resolve(), target)
        if local is None:
            continue
        target_path, fragment = local
        if not target_path.exists():
            add(
                findings,
                "error",
                "local-link",
                f"missing local link target: {target}",
                number,
            )
        elif fragment and target_path == readme.resolve() and github_anchor(fragment) not in anchors:
            add(
                findings,
                "error",
                "anchor-link",
                f"missing README anchor: #{fragment}",
                number,
            )

    for match in IMAGE_RE.finditer(visible):
        alt, target = match.groups()
        if not alt.strip():
            add(
                findings,
                "error",
                "image-alt",
                f"image has empty alternative text: {target}",
                line_number(visible, match.start()),
            )
        if " " in target and "%20" not in target:
            add(
                findings,
                "warning",
                "image-space",
                f"image URL contains an unencoded space: {target}",
                line_number(visible, match.start()),
            )

    for match in HTML_IMAGE_RE.finditer(visible):
        attributes = match.group(1)
        number = line_number(visible, match.start())
        if not re.search(r"\balt\s*=", attributes, re.IGNORECASE):
            add(findings, "error", "html-image-alt", "HTML image is missing alt", number)
        if re.search(r"\balign\s*=", attributes, re.IGNORECASE):
            add(
                findings,
                "warning",
                "mobile-image-align",
                "HTML image alignment is unreliable on mobile GitHub",
                number,
            )
    for number, line in visible_lines:
        if re.search(r"<div\b", line, re.IGNORECASE):
            add(
                findings,
                "warning",
                "raw-div",
                "raw <div> layouts may not render consistently on GitHub",
                number,
            )
        if line.rstrip(" \t") != line:
            add(findings, "warning", "trailing-space", "trailing whitespace", number)

    check_tables(visible_lines, findings)
    if check_external:
        check_external_links(external_urls, findings)

    prose = re.sub(r"`[^`]+`", "", visible)
    prose = re.sub(r"!?\[([^\]]*)\]\([^)]+\)", r"\1", prose)
    prose = re.sub(r"<[^>]+>", "", prose)
    words = re.findall(r"\b[\w'-]+\b", prose)
    sentences = max(1, len(re.findall(r"[.!?](?:\s|$)", prose)))
    statistics = {
        "lines": len(content.splitlines()),
        "headings": len(headings),
        "links": len(LINK_RE.findall(visible)),
        "images": len(IMAGE_RE.findall(visible)) + len(HTML_IMAGE_RE.findall(visible)),
        "words": len(words),
        "average_words_per_sentence": round(len(words) / sentences, 1),
        "fence_markers": fence_count,
    }
    return findings, statistics


def print_findings(readme: Path, findings: list[Finding]) -> None:
    for finding in findings:
        annotation = "error" if finding.level == "error" else "warning"
        print(
            f"::{annotation} file={readme},line={finding.line},"
            f"title={finding.code}::{finding.message}"
        )
    errors = sum(finding.level == "error" for finding in findings)
    warnings = sum(finding.level == "warning" for finding in findings)
    print(f"README policy result: {errors} error(s), {warnings} warning(s)")


def write_report(
    path: Path,
    readme: Path,
    policy_path: Path,
    findings: list[Finding],
    statistics: dict[str, Any],
) -> None:
    report = {
        "schema_version": 1,
        "readme": str(readme),
        "policy": str(policy_path),
        "statistics": statistics,
        "summary": {
            "errors": sum(f.level == "error" for f in findings),
            "warnings": sum(f.level == "warning" for f in findings),
        },
        "findings": [asdict(finding) for finding in findings],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def reconcile(readme: Path, policy: dict[str, Any], output: Path) -> bool:
    content = readme.read_text(encoding="utf-8")
    changed = False
    for name, lines in policy.get("managed_blocks", {}).items():
        pattern = re.compile(
            rf"(<!-- README-AUTO:start:{re.escape(name)} -->).*?"
            rf"(<!-- README-AUTO:end:{re.escape(name)} -->)",
            re.DOTALL,
        )
        block = "\n".join(lines)
        updated, count = pattern.subn(
            lambda match: f"{match.group(1)}\n{block}\n{match.group(2)}",
            content,
            count=1,
        )
        if count != 1:
            raise ValueError(f"README must contain one managed block {name!r}")
        if updated != content:
            changed = True
            content = updated
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")
    return changed


def staleness(readme: Path, policy: dict[str, Any]) -> tuple[int, int]:
    try:
        timestamp = int(
            subprocess.check_output(
                ["git", "log", "-1", "--format=%ct", "--", str(readme)],
                text=True,
            ).strip()
        )
    except (subprocess.CalledProcessError, ValueError):
        timestamp = int(readme.stat().st_mtime)
    age_days = int((time.time() - timestamp) // 86400)
    threshold = int(policy.get("stale_after_days", 180))
    return age_days, threshold


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--readme", type=Path, default=Path("README.md"))
    parser.add_argument(
        "--policy", type=Path, default=Path("config/readme-policy.json")
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    quality_parser = subparsers.add_parser("quality")
    quality_parser.add_argument("--report", type=Path, default=Path("readme-report.json"))
    quality_parser.add_argument("--check-external", action="store_true")
    quality_parser.add_argument("--strict", action="store_true")

    reconcile_parser = subparsers.add_parser("reconcile")
    reconcile_parser.add_argument("--output", type=Path, required=True)

    subparsers.add_parser("staleness")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        policy = load_policy(args.policy)
        if args.command == "quality":
            findings, statistics = quality(args.readme, policy, args.check_external)
            write_report(args.report, args.readme, args.policy, findings, statistics)
            print_findings(args.readme, findings)
            errors = any(finding.level == "error" for finding in findings)
            warnings = any(finding.level == "warning" for finding in findings)
            strict = args.strict or bool(policy.get("strict_warnings"))
            return 1 if errors or (strict and warnings) else 0
        if args.command == "reconcile":
            changed = reconcile(args.readme, policy, args.output)
            print("README proposal differs from source." if changed else "README is current.")
            return 0
        if args.command == "staleness":
            age_days, threshold = staleness(args.readme, policy)
            print(f"README age: {age_days} day(s); policy threshold: {threshold} day(s).")
            if age_days > threshold:
                print("::warning title=README staleness::README exceeds its review threshold")
            return 0
        return 2
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        print(f"readme-policy: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
