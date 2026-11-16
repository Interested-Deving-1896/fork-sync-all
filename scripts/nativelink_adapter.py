#!/usr/bin/env python3
"""Render safe Bazel Remote Execution API flags for an optional NativeLink endpoint.

This adapter only validates configuration and renders command-line flags. It
never starts a build, contacts NativeLink, or reads/prints credentials.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from urllib.parse import urlsplit


class NativeLinkConfigError(ValueError):
    """NativeLink endpoint configuration is invalid."""


def validate_endpoint(value: str, label: str) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise NativeLinkConfigError(f"{label} must be a non-empty endpoint URL")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as exc:
        raise NativeLinkConfigError(f"{label} is malformed") from exc
    if (parsed.scheme not in {"grpc", "grpcs"} or not parsed.hostname
            or port is None or not 1 <= port <= 65535
            or parsed.username is not None or parsed.password is not None
            or parsed.path not in {"", "/"} or parsed.query or parsed.fragment):
        raise NativeLinkConfigError(
            f"{label} must use grpc:// or grpcs:// with a host and explicit port"
        )
    return value.rstrip("/")


def build_bazel_flags(
    executor: str | None,
    cache: str | None,
    instance_name: str | None = None,
) -> list[str]:
    flags: list[str] = []
    if executor:
        flags.append(f"--remote_executor={validate_endpoint(executor, 'executor endpoint')}")
    if cache:
        flags.append(f"--remote_cache={validate_endpoint(cache, 'cache endpoint')}")
    if instance_name:
        if (len(instance_name) > 256
                or not re.fullmatch(r"[A-Za-z0-9._/-]+", instance_name)
                or ".." in instance_name.split("/")):
            raise NativeLinkConfigError("instance name contains unsupported characters")
        flags.append(f"--remote_instance_name={instance_name}")
    if not flags:
        raise NativeLinkConfigError(
            "configure NATIVE_LINK_EXECUTOR and/or NATIVE_LINK_CACHE"
        )
    return flags


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executor", default=os.environ.get("NATIVE_LINK_EXECUTOR"))
    parser.add_argument("--cache", default=os.environ.get("NATIVE_LINK_CACHE"))
    parser.add_argument(
        "--instance-name", default=os.environ.get("NATIVE_LINK_INSTANCE_NAME")
    )
    parser.add_argument("--format", choices=("bazel", "json"), default="bazel")
    args = parser.parse_args(argv)
    try:
        flags = build_bazel_flags(args.executor, args.cache, args.instance_name)
    except NativeLinkConfigError as exc:
        print(f"nativelink-adapter: {exc}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps({"provider": "nativelink", "bazel_flags": flags}, sort_keys=True))
    else:
        print("\n".join(flags))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
