#!/usr/bin/env python3
"""Offline-first AI conversation export validator and Markdown renderer."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

SCHEMA_VERSION = "1.0"
ALLOWED_PROVIDERS = {
    "chatgpt": {"chatgpt.com"},
    "gemini": {"gemini.google.com"},
    "claude": {"claude.ai"},
    "grok": {"grok.com", "x.com"},
    "deepseek": {"chat.deepseek.com"},
}
ALLOWED_ROLES = {"user", "assistant", "system", "tool"}
MAX_INPUT_BYTES = 10 * 1024 * 1024
CONTROL_CHARS = re.compile(r"[\r\n\x00]")


class BridgeError(ValueError):
    """Expected input or validation error."""


def validate_source_url(provider: str, value: str) -> str:
    """Validate provenance URL without fetching it."""
    if not value:
        return ""
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise BridgeError("source.url must be HTTPS without embedded credentials")
    allowed = ALLOWED_PROVIDERS.get(provider)
    if allowed is None:
        raise BridgeError(f"unsupported provider: {provider}")
    host = parsed.hostname.lower().rstrip(".")
    if not any(host == domain or host.endswith("." + domain) for domain in allowed):
        raise BridgeError(f"URL host is not allowlisted for provider {provider}")
    return value


def load_conversation(path: Path) -> dict:
    if not path.is_file():
        raise BridgeError("input file does not exist or is not a regular file")
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise BridgeError(f"input exceeds {MAX_INPUT_BYTES} byte limit")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError("input must be valid UTF-8 JSON") from exc
    validate_conversation(data)
    return data


def validate_conversation(data: object) -> None:
    if not isinstance(data, dict):
        raise BridgeError("root must be a JSON object")
    if data.get("schema_version", SCHEMA_VERSION) != SCHEMA_VERSION:
        raise BridgeError(f"schema_version must be {SCHEMA_VERSION}")
    title = data.get("title", "Untitled AI conversation")
    if not isinstance(title, str) or not title.strip() or CONTROL_CHARS.search(title):
        raise BridgeError("title must be non-empty and contain no line breaks/control characters")
    source = data.get("source", {})
    if not isinstance(source, dict):
        raise BridgeError("source must be an object")
    provider = source.get("provider", "generic")
    url = source.get("url", "")
    if provider != "generic":
        validate_source_url(provider, url)
    elif url:
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise BridgeError("generic source URL must be HTTPS")
    messages = data.get("messages")
    if not isinstance(messages, list) or not messages:
        raise BridgeError("messages must be a non-empty array")
    for index, message in enumerate(messages):
        if not isinstance(message, dict):
            raise BridgeError(f"messages[{index}] must be an object")
        if message.get("role") not in ALLOWED_ROLES:
            raise BridgeError(f"messages[{index}].role is unsupported")
        if not isinstance(message.get("content"), str):
            raise BridgeError(f"messages[{index}].content must be a string")


def render_markdown(data: dict, imported_at: str | None = None) -> str:
    validate_conversation(data)
    source = data.get("source", {})
    provider = source.get("provider", "generic")
    source_url = source.get("url", "")
    if provider != "generic":
        source_url = validate_source_url(provider, source_url)
    title = data.get("title", "Untitled AI conversation").strip()
    # Escape Markdown heading metacharacters so imported titles cannot alter structure.
    title = re.sub(r"([\\`*_{}\[\]()#+.!|>~-])", r"\\\1", title)
    imported_at = imported_at or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    canonical = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(canonical).hexdigest()
    # JSON string quoting is a valid YAML scalar style for these values.
    lines = [
        "---",
        f"schema_version: {json.dumps(SCHEMA_VERSION)}",
        f"source_provider: {json.dumps(provider)}",
        f"source_url: {json.dumps(source_url)}",
        f"imported_at: {json.dumps(imported_at)}",
        f"content_sha256: {json.dumps(digest)}",
        "---", "",
        f"# {title}", "",
        f"> Imported from **{provider}**. Original: {source_url or 'not supplied'}", "",
    ]
    labels = {"user": "User", "assistant": "Assistant", "system": "System", "tool": "Tool"}
    for message in data["messages"]:
        lines.extend([f"## {labels[message['role']]}", "", message["content"].rstrip(), ""])
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate_cmd = commands.add_parser("validate")
    validate_cmd.add_argument("input", type=Path)
    render_cmd = commands.add_parser("render")
    render_cmd.add_argument("input", type=Path)
    render_cmd.add_argument("--output", "-o", type=Path, help="Markdown output path (default: stdout)")
    args = parser.parse_args(argv)
    try:
        data = load_conversation(args.input)
        if args.command == "validate":
            print("valid conversation schema")
            return 0
        markdown = render_markdown(data)
        if args.output:
            args.output.write_text(markdown, encoding="utf-8")
        else:
            sys.stdout.write(markdown)
        return 0
    except BridgeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
