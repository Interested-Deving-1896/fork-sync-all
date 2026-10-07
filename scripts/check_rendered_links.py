#!/usr/bin/env python3
"""Validate local links and fragments in a rendered HTML documentation tree."""

from __future__ import annotations

import argparse
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urlsplit
from urllib.request import Request, urlopen


class DocumentParser(HTMLParser):
    """Collect navigational links and addressable element identifiers."""

    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []
        self.identifiers: set[str] = set()

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        values = dict(attrs)
        identifier = values.get("id") or values.get("name")
        if identifier:
            self.identifiers.add(identifier)
        if tag == "a" and values.get("href"):
            self.links.append(values["href"] or "")


def read_document(path: Path) -> DocumentParser:
    parser = DocumentParser()
    parser.feed(path.read_text(encoding="utf-8"))
    return parser


def resolve_local_target(
    root: Path, source: Path, raw_path: str, site_prefix: str
) -> Path:
    decoded = unquote(raw_path)
    if decoded.startswith("/"):
        if not site_prefix or not decoded.startswith(site_prefix):
            raise ValueError("root-relative link is outside the configured site prefix")
        decoded = decoded[len(site_prefix) :]
        candidate = root / decoded
    else:
        candidate = source.parent / decoded
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ValueError("link escapes the rendered documentation root") from exc
    if resolved.is_dir():
        resolved /= "index.html"
    return resolved


def validate(root: Path, site_prefix: str) -> tuple[list[str], set[str]]:
    root = root.resolve()
    if not root.is_dir():
        return [f"rendered documentation directory does not exist: {root}"], set()

    if site_prefix and not site_prefix.endswith("/"):
        site_prefix += "/"
    documents = {
        path.resolve(): read_document(path) for path in sorted(root.rglob("*.html"))
    }
    errors: list[str] = []
    external_urls: set[str] = set()
    checked: set[tuple[Path, str]] = set()

    for source, document in list(documents.items()):
        source_label = source.relative_to(root)
        for href in document.links:
            parsed = urlsplit(href)
            if parsed.scheme in {"http", "https"}:
                external_urls.add(href)
                continue
            if parsed.scheme in {"mailto", "tel", "data", "javascript"}:
                continue
            if parsed.netloc:
                continue
            raw_path = parsed.path
            target = source if not raw_path else None
            if target is None:
                try:
                    target = resolve_local_target(root, source, raw_path, site_prefix)
                except ValueError as exc:
                    errors.append(f"{source_label}: {href}: {exc}")
                    continue
            key = (target, parsed.fragment)
            if key in checked:
                continue
            checked.add(key)
            if not target.exists():
                errors.append(
                    f"{source_label}: {href}: missing rendered target "
                    f"{PurePosixPath(target.relative_to(root).as_posix())}"
                )
                continue
            if parsed.fragment and target.suffix.casefold() == ".html":
                target_document = documents.get(target)
                if target_document is None:
                    try:
                        target_document = read_document(target)
                    except (OSError, UnicodeDecodeError) as exc:
                        errors.append(f"{source_label}: {href}: cannot parse target: {exc}")
                        continue
                    documents[target] = target_document
                fragment = unquote(parsed.fragment)
                if fragment not in target_document.identifiers:
                    errors.append(
                        f"{source_label}: {href}: missing rendered fragment {fragment!r}"
                    )
    return errors, external_urls


def check_external_url(url: str, timeout: float) -> str | None:
    request = Request(
        url,
        headers={
            "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
            "User-Agent": "Mozilla/5.0 rendered-documentation-link-audit",
        },
    )
    last_error = "request failed"
    for attempt in range(3):
        try:
            with urlopen(request, timeout=timeout) as response:
                response.read(1)
                if response.status < 400:
                    return None
                last_error = f"HTTP {response.status}"
        except HTTPError as exc:
            last_error = f"HTTP {exc.code}"
            if exc.code not in {429, 500, 502, 503, 504}:
                return last_error
        except (OSError, URLError, TimeoutError) as exc:
            last_error = f"{type(exc).__name__}: {exc}"
        if attempt < 2:
            time.sleep(0.5 * (attempt + 1))
    return last_error


def validate_external(urls: set[str], timeout: float) -> list[str]:
    errors: list[str] = []
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(check_external_url, url, timeout): url
            for url in sorted(urls)
        }
        for future in as_completed(futures):
            error = future.result()
            if error:
                errors.append(f"{futures[future]}: {error}")
    return sorted(errors)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="rendered documentation directory")
    parser.add_argument(
        "--site-prefix",
        default="",
        help="expected root-relative deployment prefix, such as /project/",
    )
    parser.add_argument(
        "--check-external",
        action="store_true",
        help="also request every unique HTTP(S) link",
    )
    parser.add_argument(
        "--external-timeout",
        type=float,
        default=20.0,
        help="per-request timeout for external links",
    )
    args = parser.parse_args()
    errors, external_urls = validate(args.root, args.site_prefix)
    if args.check_external:
        errors.extend(validate_external(external_urls, args.external_timeout))
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Rendered link validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1
    count = sum(1 for _ in args.root.rglob("*.html"))
    print(f"Validated local links and fragments across {count} rendered HTML files.")
    if args.check_external:
        print(f"Validated {len(external_urls)} unique external HTTP(S) links.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
