"""Read-only repository tree inventory for dependency and provenance manifests.

This module lists candidate files from GitHub's Git tree API. It does not fetch or
execute project files and makes no repository changes.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API = "https://api.github.com"
MANIFEST_GROUPS = {
    "python": {"pyproject.toml", "requirements.txt", "Pipfile", "poetry.lock", "uv.lock", "setup.py"},
    "javascript": {"package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"},
    "rust": {"Cargo.toml", "Cargo.lock"},
    "go": {"go.mod", "go.sum"},
    "ruby": {"Gemfile", "Gemfile.lock"},
    "php": {"composer.json", "composer.lock"},
    "java_jvm": {"pom.xml", "build.gradle", "build.gradle.kts", "gradle.lockfile"},
    "dotnet": {"*.csproj", "*.fsproj", "*.vbproj", "packages.lock.json"},
    "containers": {"Dockerfile", "Containerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"},
    "nix": {"flake.nix", "flake.lock"},
    "submodules": {".gitmodules"},
    "sbom": {"bom.json", "sbom.json", "bom.xml", "spdx.json", "spdx.rdf"},
    "license": {"LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "NOTICE"},
}


def classify_paths(paths: list[str]) -> dict[str, list[str]]:
    """Group candidate inventory files by basename; preserve exact repository paths."""
    result = {group: [] for group in MANIFEST_GROUPS}
    for path in paths:
        basename = path.rsplit("/", 1)[-1]
        for group, patterns in MANIFEST_GROUPS.items():
            if basename in patterns or any(
                pattern.startswith("*.") and basename.endswith(pattern[1:])
                for pattern in patterns
            ):
                result[group].append(path)
    return {key: sorted(set(value)) for key, value in result.items() if value}


def fetch_tree(repository: str, default_branch: str, token: str | None = None) -> dict[str, Any]:
    """Fetch the recursive Git tree and return classified candidate paths."""
    parts = repository.split("/")
    if len(parts) != 2 or not all(parts):
        raise ValueError("repository must be OWNER/NAME")
    owner, name = (urllib.parse.quote(part, safe="") for part in parts)
    branch = urllib.parse.quote(default_branch, safe="")
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "fork-sync-all-upstream-engine/0.1",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(f"{API}/repos/{owner}/{name}/git/trees/{branch}?recursive=1", headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Git tree inventory failed: {exc}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("tree"), list):
        raise RuntimeError("unexpected Git tree response")
    paths = [
        item["path"] for item in payload["tree"]
        if isinstance(item, dict) and item.get("type") == "blob" and isinstance(item.get("path"), str)
    ]
    return {
        "repository": repository,
        "default_branch": default_branch,
        "tree_truncated": bool(payload.get("truncated")),
        "candidate_files": classify_paths(paths),
        "candidate_count": sum(len(items) for items in classify_paths(paths).values()),
        "limitations": [
            "Candidate paths are not proof that dependencies are complete or current",
            "Manifest contents have not been parsed or resolved",
            "GitHub may return a truncated recursive tree for large repositories",
            "No project code was executed",
        ],
    }


def inventory_from_environment(repository: str, default_branch: str) -> dict[str, Any]:
    """Convenience wrapper using an optional read-only token from the environment."""
    return fetch_tree(repository, default_branch, os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
