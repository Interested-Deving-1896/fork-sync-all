#!/usr/bin/env python3
"""Extract and validate external links from Markdown without scanning code as prose."""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from html.parser import HTMLParser
from pathlib import Path
from typing import Callable, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
REFERENCE = re.compile(
    r"^ {0,3}\[[^]]+\]:\s*(?:<([^>]+)>|([^\s]+))(?:\s+(?:['\"(].*)?)?$"
)
AUTOLINK = re.compile(r"<((?:https?://)[^<>\s]+)>", re.IGNORECASE)


@dataclass(frozen=True)
class LinkOccurrence:
    url: str
    path: str
    line: int


@dataclass
class LinkResult:
    url: str
    healthy: bool
    status: int | None
    attempts: int
    error: str
    occurrences: list[dict[str, object]]


class HTMLLinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[tuple[str, int]] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        if tag.casefold() != "a":
            return
        href = dict(attrs).get("href")
        if href:
            self.links.append((href, self.getpos()[0]))


def _strip_comments_and_code(text: str) -> str:
    """Blank fenced, indented, inline-code, and HTML-comment content."""
    output: list[str] = []
    fence: tuple[str, int] | None = None
    in_comment = False
    for raw_line in text.splitlines(keepends=True):
        line = raw_line
        marker = FENCE.match(line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = (token[0], len(token))
            elif token[0] == fence[0] and len(token) >= fence[1]:
                fence = None
            output.append("\n" if raw_line.endswith("\n") else "")
            continue
        if fence is not None or line.startswith("    ") or line.startswith("\t"):
            output.append("\n" if raw_line.endswith("\n") else "")
            continue

        chars = list(line)
        index = 0
        while index < len(chars):
            if in_comment:
                end = line.find("-->", index)
                if end < 0:
                    for position in range(index, len(chars)):
                        if chars[position] != "\n":
                            chars[position] = " "
                    index = len(chars)
                    continue
                for position in range(index, end + 3):
                    if chars[position] != "\n":
                        chars[position] = " "
                in_comment = False
                index = end + 3
                continue
            if line.startswith("<!--", index):
                in_comment = True
                continue
            if chars[index] == "`":
                run = 1
                while index + run < len(chars) and chars[index + run] == "`":
                    run += 1
                end = line.find("`" * run, index + run)
                if end >= 0:
                    for position in range(index, end + run):
                        chars[position] = " "
                    index = end + run
                    continue
            index += 1
        output.append("".join(chars))
    return "".join(output)


def _closing_bracket(text: str, start: int, opening: str, closing: str) -> int:
    depth = 0
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
    return -1


def _inline_destination(text: str, opening: int) -> tuple[str, int] | None:
    index = opening + 1
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text):
        return None
    if text[index] == "<":
        end = text.find(">", index + 1)
        if end < 0:
            return None
        destination = text[index + 1 : end]
        close = text.find(")", end + 1)
        return (destination, close) if close >= 0 else None

    start = index
    nested = 0
    escaped = False
    while index < len(text):
        char = text[index]
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "(":
            nested += 1
        elif char == ")":
            if nested == 0:
                return text[start:index].split(maxsplit=1)[0], index
            nested -= 1
        elif char.isspace() and nested == 0:
            close = text.find(")", index)
            if close >= 0:
                return text[start:index], close
            return None
        index += 1
    return None


def _is_external(url: str) -> bool:
    return urlsplit(url).scheme.casefold() in {"http", "https"}


def extract_links(path: Path) -> list[LinkOccurrence]:
    text = _strip_comments_and_code(path.read_text(encoding="utf-8"))
    occurrences: list[LinkOccurrence] = []
    lines = text.splitlines()
    for line_number, line in enumerate(lines, 1):
        match = REFERENCE.match(line)
        if match:
            destination = match.group(1) or match.group(2) or ""
            if _is_external(destination):
                occurrences.append(LinkOccurrence(destination, str(path), line_number))
    for match in AUTOLINK.finditer(text):
        occurrences.append(
            LinkOccurrence(match.group(1), str(path), text.count("\n", 0, match.start()) + 1)
        )

    index = 0
    while index < len(text):
        opening = text.find("[", index)
        if opening < 0:
            break
        if opening > 0 and text[opening - 1] == "!":
            index = opening + 1
            continue
        closing = _closing_bracket(text, opening, "[", "]")
        if closing < 0:
            break
        cursor = closing + 1
        while cursor < len(text) and text[cursor] in " \t\n":
            cursor += 1
        if cursor < len(text) and text[cursor] == "(":
            parsed = _inline_destination(text, cursor)
            if parsed:
                destination, end = parsed
                if _is_external(destination):
                    occurrences.append(
                        LinkOccurrence(
                            destination.replace("\\)", ")"),
                            str(path),
                            text.count("\n", 0, opening) + 1,
                        )
                    )
                index = end + 1
                continue
        index = closing + 1

    parser = HTMLLinkParser()
    parser.feed(text)
    occurrences.extend(
        LinkOccurrence(url, str(path), line) for url, line in parser.links if _is_external(url)
    )
    return sorted(set(occurrences), key=lambda item: (item.url, item.path, item.line))


def discover_markdown(paths: Iterable[Path], excludes: list[str]) -> list[Path]:
    discovered: set[Path] = set()
    for path in paths:
        if path.is_dir():
            candidates = path.rglob("*.md")
        elif path.is_file():
            candidates = [path]
        else:
            raise FileNotFoundError(path)
        for candidate in candidates:
            relative = candidate.as_posix()
            if not any(fnmatch.fnmatch(relative, pattern) for pattern in excludes):
                discovered.add(candidate)
    return sorted(discovered)


def check_url(
    url: str,
    timeout: float,
    retries: int,
    retry_delay: float,
    opener: Callable[..., object] = urlopen,
    sleeper: Callable[[float], None] = time.sleep,
    allowed_statuses: set[int] | None = None,
) -> tuple[bool, int | None, int, str]:
    allowed_statuses = allowed_statuses or set()
    request = Request(
        url,
        headers={
            "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
            "Range": "bytes=0-0",
            "User-Agent": "Mozilla/5.0 fork-sync-all-markdown-link-audit/1.0",
        },
    )
    attempts = retries + 1
    last_status: int | None = None
    last_error = "request failed"
    for attempt in range(1, attempts + 1):
        try:
            with opener(request, timeout=timeout) as response:  # type: ignore[attr-defined]
                status = int(getattr(response, "status", response.getcode()))
                response.read(1)
                if 200 <= status < 400 or status in allowed_statuses:
                    return True, status, attempt, ""
                last_status, last_error = status, f"HTTP {status}"
                if status not in {408, 425, 429, 500, 502, 503, 504}:
                    return False, status, attempt, last_error
        except HTTPError as exc:
            last_status, last_error = exc.code, f"HTTP {exc.code}"
            exc.close()
            if exc.code in allowed_statuses:
                return True, exc.code, attempt, "allowed status"
            if exc.code not in {408, 425, 429, 500, 502, 503, 504}:
                return False, exc.code, attempt, last_error
        except (OSError, URLError, TimeoutError) as exc:
            last_error = f"{type(exc).__name__}: {exc}"
        if attempt < attempts:
            sleeper(retry_delay * attempt)
    return False, last_status, attempts, last_error


def audit(
    occurrences: list[LinkOccurrence], timeout: float, retries: int, retry_delay: float,
    workers: int, allowed_statuses: set[int] | None = None,
) -> dict[str, object]:
    by_url: dict[str, list[LinkOccurrence]] = {}
    for occurrence in occurrences:
        by_url.setdefault(occurrence.url, []).append(occurrence)
    results: list[LinkResult] = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        pending = {
            executor.submit(
                check_url, url, timeout, retries, retry_delay,
                allowed_statuses=allowed_statuses,
            ): url
            for url in by_url
        }
        for future in as_completed(pending):
            url = pending[future]
            healthy, status, attempts, error = future.result()
            results.append(
                LinkResult(
                    url=url,
                    healthy=healthy,
                    status=status,
                    attempts=attempts,
                    error=error,
                    occurrences=[asdict(item) for item in by_url[url]],
                )
            )
    results.sort(key=lambda item: item.url)
    return {
        "schema_version": 1,
        "healthy": all(item.healthy for item in results),
        "links_checked": len(results),
        "occurrences": len(occurrences),
        "results": [asdict(item) for item in results],
    }


def render_markdown(report: dict[str, object]) -> str:
    results = report["results"]
    assert isinstance(results, list)
    failures = [item for item in results if not item["healthy"]]
    lines = [
        "# Markdown external-link audit",
        "",
        f"**Overall:** {'Healthy' if report['healthy'] else 'Attention required'}",
        "",
        f"Unique links checked: **{report['links_checked']}**  ",
        f"Markdown occurrences: **{report['occurrences']}**  ",
        f"Failures: **{len(failures)}**",
        "",
    ]
    if failures:
        lines.extend(["| URL | Result | Source |", "|---|---|---|"])
        for item in failures:
            locations = ", ".join(
                f"`{entry['path']}:{entry['line']}`" for entry in item["occurrences"]
            )
            lines.append(f"| {item['url']} | {item['error']} | {locations} |")
    else:
        lines.append("All external Markdown links passed the configured status policy.")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--retry-delay", type=float, default=0.5)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument(
        "--allow-status",
        action="append",
        default=[],
        type=int,
        help="treat an HTTP status as allowed while retaining it in the report",
    )
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--output-markdown", type=Path)
    args = parser.parse_args()
    try:
        files = discover_markdown(args.paths, args.exclude)
        occurrences = [item for path in files for item in extract_links(path)]
        report = audit(
            occurrences, args.timeout, args.retries, args.retry_delay, args.workers,
            set(args.allow_status),
        )
        rendered = render_markdown(report)
        if args.output_json:
            args.output_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if args.output_markdown:
            args.output_markdown.write_text(rendered, encoding="utf-8")
        print(rendered)
        return 0 if report["healthy"] else 1
    except (OSError, ValueError) as exc:
        print(f"check-markdown-links: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
