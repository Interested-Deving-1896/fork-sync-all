"""Opt-in GitHub repository adapter for the Project Creation Engine.

This adapter performs real provider mutations only when called by an explicitly
authorized execution path. Unit tests mock HTTP; no credentials or live writes
are used by this module's test suite.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import PurePosixPath
import re
from typing import Any, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

from scripts.project_creation_engine import CreationPlan, ProjectSpecError, Template


class GitHubProviderError(RuntimeError):
    """A GitHub API operation failed; response bodies and secrets are omitted."""


class GitHubRepositoryAdapter:
    """Create and verify repositories under one explicitly configured owner.

    Pass a narrowly scoped token at runtime (or set GITHUB_TOKEN). The adapter
    never logs or returns the token. For personal repositories, owner must match
    the authenticated account. For organization repositories, use owner_type
    "org" and ensure the token has the required repository permissions.
    """

    provider_id = "github"

    def __init__(
        self,
        owner: str,
        *,
        token: str | None = None,
        owner_type: str = "user",
        timeout: float = 15.0,
    ) -> None:
        if not isinstance(owner, str) or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", owner):
            raise ValueError("owner must be a valid GitHub account or organization name")
        if owner_type not in ("user", "org"):
            raise ValueError("owner_type must be 'user' or 'org'")
        if not isinstance(timeout, (int, float)) or timeout <= 0:
            raise ValueError("timeout must be positive")
        resolved_token = token if token is not None else os.environ.get("GITHUB_TOKEN")
        if not isinstance(resolved_token, str) or not resolved_token.strip():
            raise ValueError("a GitHub token must be supplied at runtime")
        self.owner = owner
        self.owner_type = owner_type
        # Never allow caller-controlled API hosts: the bearer token must only
        # be sent to GitHub's official API origin.
        self.api_url = "https://api.github.com"
        self.timeout = float(timeout)
        self._token = resolved_token.strip()
        self._verification_expectations: dict[str, dict[str, Any]] = {}

    def capabilities(self) -> set[str]:
        return {"repository_create_from_template"}

    def _request(
        self,
        method: str,
        path: str,
        payload: Mapping[str, Any] | None = None,
        *,
        allow_not_found: bool = False,
    ) -> Mapping[str, Any] | None:
        url = self.api_url + path
        body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        request = Request(
            url,
            data=body,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "fork-sync-all-project-creation-engine",
                **({"Content-Type": "application/json"} if body is not None else {}),
            },
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except HTTPError as exc:
            if allow_not_found and exc.code == 404:
                return None
            # Do not expose provider response bodies, which can contain sensitive details.
            raise GitHubProviderError(f"GitHub API request failed with HTTP {exc.code}") from None
        except (URLError, TimeoutError, OSError):
            raise GitHubProviderError("GitHub API transport failed; outcome may be ambiguous") from None
        if not raw:
            return {}
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise GitHubProviderError("GitHub API returned an invalid JSON response") from None
        if not isinstance(parsed, Mapping):
            raise GitHubProviderError("GitHub API returned an unexpected response shape")
        return parsed

    def _repo_path(self, name: str) -> str:
        return f"/repos/{quote(self.owner, safe='')}/{quote(name, safe='')}"

    def repository_exists(self, name: str) -> bool:
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", name):
            raise ProjectSpecError("repository name is invalid")
        return self._request("GET", self._repo_path(name), allow_not_found=True) is not None

    @staticmethod
    def _safe_file_path(path: str) -> str:
        if (
            not isinstance(path, str)
            or not path
            or "\\" in path
            or any(ord(char) < 32 or ord(char) == 127 for char in path)
        ):
            raise ProjectSpecError("template file path is unsafe")
        pure = PurePosixPath(path)
        if pure.is_absolute() or any(part in ("", ".", "..") for part in path.split("/")):
            raise ProjectSpecError("template file path is unsafe")
        if ":" in pure.parts[0]:
            raise ProjectSpecError("template file path is unsafe")
        return "/".join(quote(part, safe="") for part in pure.parts)

    def create_from_template(self, plan: CreationPlan, idempotency_key: str) -> Mapping[str, Any]:
        if plan.provider != self.provider_id:
            raise ProjectSpecError("creation plan provider does not match GitHub adapter")
        if not isinstance(idempotency_key, str) or not idempotency_key.strip():
            raise ProjectSpecError("idempotency key is required")
        if not plan.template_files or set(plan.template_sha256) != set(plan.template_files):
            raise ProjectSpecError("a verified, non-empty template bundle is required")
        for path, content in plan.template_files.items():
            self._safe_file_path(path)
            if not isinstance(content, str) or hashlib.sha256(content.encode("utf-8")).hexdigest() != plan.template_sha256[path]:
                raise ProjectSpecError("template bundle checksum verification failed")

        if self.owner_type == "user":
            account = self._request("GET", "/user")
            if account is None or str(account.get("login", "")).casefold() != self.owner.casefold():
                raise ProjectSpecError("configured owner must match the authenticated GitHub user")

        visibility = plan.visibility
        if visibility not in ("private", "public", "internal"):
            raise ProjectSpecError("repository visibility must be private, public, or internal")
        payload: dict[str, Any] = {
            "name": plan.repository_name,
            "description": plan.description,
            "auto_init": False,
        }
        if visibility == "internal":
            if self.owner_type != "org":
                raise ProjectSpecError("internal visibility is only supported for organization repositories")
            payload["visibility"] = "internal"
        else:
            payload["private"] = visibility == "private"
        endpoint = "/user/repos" if self.owner_type == "user" else f"/orgs/{quote(self.owner, safe='')}/repos"
        created = self._request("POST", endpoint, payload)
        if not created or not isinstance(created.get("full_name"), str):
            raise GitHubProviderError("GitHub did not confirm repository creation")
        if created["full_name"].casefold() != f"{self.owner}/{plan.repository_name}".casefold():
            raise GitHubProviderError("GitHub returned an unexpected repository owner")
        repo_path = self._repo_path(plan.repository_name)
        self._verification_expectations[plan.repository_name] = {
            "visibility": visibility,
            "files": dict(plan.template_files),
            "checksums": dict(plan.template_sha256),
        }
        for file_path, content in sorted(plan.template_files.items()):
            encoded_path = self._safe_file_path(file_path)
            self._request(
                "PUT",
                f"{repo_path}/contents/{encoded_path}",
                {
                    "message": f"Initialize from {plan.template_id}@{plan.template_version}",
                    "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
                },
            )
        return {
            "repository": created["full_name"],
            "seeded_paths": sorted(plan.template_files),
            "creation_method": "create_repository_then_seed_verified_bundle",
        }

    def verify_created_project(self, name: str, template: Template) -> Mapping[str, Any]:
        expected = self._verification_expectations.get(name)
        repository = self._request("GET", self._repo_path(name), allow_not_found=True)
        expected_visibility = expected.get("visibility") if expected else None
        expected_full_name = f"{self.owner}/{name}".casefold()
        metadata_ok = bool(
            repository
            and expected
            and repository.get("name") == name
            and str(repository.get("full_name", "")).casefold() == expected_full_name
            and repository.get("visibility") == expected_visibility
            and repository.get("private") is (expected_visibility != "public")
        )

        seeded_ok = bool(repository and expected and expected.get("files"))
        if seeded_ok:
            files = expected["files"]
            checksums = expected["checksums"]
            for file_path, expected_content in files.items():
                encoded_path = self._safe_file_path(file_path)
                item = self._request(
                    "GET", f"{self._repo_path(name)}/contents/{encoded_path}", allow_not_found=True
                )
                if not item or item.get("encoding") != "base64" or not isinstance(item.get("content"), str):
                    seeded_ok = False
                    break
                try:
                    actual = base64.b64decode(item["content"], validate=False).decode("utf-8")
                except (ValueError, UnicodeDecodeError):
                    seeded_ok = False
                    break
                actual_digest = hashlib.sha256(actual.encode("utf-8")).hexdigest()
                if actual_digest != checksums.get(file_path) or actual != expected_content:
                    seeded_ok = False
                    break
        return {"metadata": metadata_ok, "seeded_files": seeded_ok}
