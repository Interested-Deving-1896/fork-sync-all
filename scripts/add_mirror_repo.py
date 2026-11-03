#!/usr/bin/env python3
"""Provision a GitHub fork chain: canonical account -> OSP -> OOC.

The GitHub fork API preserves fork-network metadata. Existing destinations are
accepted only when they are already forks of the expected upstream root;
independent repositories are never overwritten or silently converted.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from typing import Any, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


class ForkChainError(RuntimeError):
    """A fork-chain operation failed or could not be verified."""


class GitHubForkChain:
    def __init__(
        self,
        token: str,
        *,
        api_url: str = "https://api.github.com",
        timeout: float = 20.0,
        poll_attempts: int = 60,
        poll_interval: float = 5.0,
        sleep=time.sleep,
    ) -> None:
        if not isinstance(token, str) or not token.strip():
            raise ValueError("GH_TOKEN is required")
        if api_url != "https://api.github.com":
            raise ValueError("only the official GitHub API origin is permitted")
        if timeout <= 0 or poll_attempts < 1 or poll_interval < 0:
            raise ValueError("invalid timeout or polling configuration")
        self._token = token.strip()
        self.api_url = api_url
        self.timeout = timeout
        self.poll_attempts = poll_attempts
        self.poll_interval = poll_interval
        self._sleep = sleep

    def _request(
        self,
        method: str,
        path: str,
        payload: Mapping[str, Any] | None = None,
        *,
        allow_not_found: bool = False,
        allow_conflict: bool = False,
    ) -> tuple[int, Mapping[str, Any] | None]:
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(
            self.api_url + path,
            data=body,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "fork-sync-all-fork-chain-provisioner",
                **({"Content-Type": "application/json"} if body is not None else {}),
            },
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
                status = response.status
        except HTTPError as exc:
            if allow_not_found and exc.code == 404:
                return 404, None
            if allow_conflict and exc.code == 422:
                return 422, None
            raise ForkChainError(f"GitHub API request failed with HTTP {exc.code}") from None
        except (URLError, TimeoutError, OSError):
            raise ForkChainError("GitHub API transport failed; fork outcome may be ambiguous") from None
        if not raw:
            return status, {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ForkChainError("GitHub API returned invalid JSON") from None
        if not isinstance(data, Mapping):
            raise ForkChainError("GitHub API returned an unexpected response shape")
        return status, data

    @staticmethod
    def _repo_path(owner: str, name: str) -> str:
        return f"/repos/{quote(owner, safe='')}/{quote(name, safe='')}"

    def get_repository(self, owner: str, name: str) -> Mapping[str, Any] | None:
        _, data = self._request("GET", self._repo_path(owner, name), allow_not_found=True)
        return data

    def request_fork(self, source_owner: str, name: str, destination_org: str) -> None:
        path = f"{self._repo_path(source_owner, name)}/forks"
        status, _ = self._request(
            "POST",
            path,
            {"organization": destination_org},
            allow_conflict=True,
        )
        if status not in (201, 202, 422):
            raise ForkChainError(f"GitHub did not accept fork creation (HTTP {status})")

    @staticmethod
    def _source_root(repository: Mapping[str, Any]) -> str:
        source = repository.get("source")
        parent = repository.get("parent")
        if isinstance(source, Mapping) and isinstance(source.get("full_name"), str):
            return source["full_name"]
        if isinstance(parent, Mapping) and isinstance(parent.get("full_name"), str):
            return parent["full_name"]
        return ""

    def _validate_existing_fork(
        self,
        repository: Mapping[str, Any],
        *,
        destination_org: str,
        name: str,
        expected_root: str,
    ) -> None:
        actual_name = repository.get("full_name")
        if actual_name != f"{destination_org}/{name}":
            raise ForkChainError(f"unexpected repository identity at {destination_org}/{name}")
        if repository.get("fork") is not True:
            raise ForkChainError(
                f"{destination_org}/{name} already exists but is not a GitHub fork; "
                "refusing to overwrite or convert it"
            )
        if self._source_root(repository) != expected_root:
            raise ForkChainError(
                f"{destination_org}/{name} belongs to a different fork network; "
                "refusing to overwrite it"
            )

    def ensure_fork(
        self,
        *,
        source_owner: str,
        destination_org: str,
        name: str,
        expected_root: str,
    ) -> Mapping[str, Any]:
        existing = self.get_repository(destination_org, name)
        if existing is not None:
            self._validate_existing_fork(
                existing,
                destination_org=destination_org,
                name=name,
                expected_root=expected_root,
            )
            return {"full_name": f"{destination_org}/{name}", "state": "already_exists"}

        self.request_fork(source_owner, name, destination_org)
        for attempt in range(self.poll_attempts):
            existing = self.get_repository(destination_org, name)
            if existing is not None:
                self._validate_existing_fork(
                    existing,
                    destination_org=destination_org,
                    name=name,
                    expected_root=expected_root,
                )
                return {"full_name": f"{destination_org}/{name}", "state": "created"}
            if attempt + 1 < self.poll_attempts:
                self._sleep(self.poll_interval)
        raise ForkChainError(
            f"timed out waiting for GitHub to create {destination_org}/{name}; "
            "inspect the fork request before retrying"
        )

    def ensure_chain(
        self,
        *,
        upstream_owner: str,
        osp_org: str,
        ooc_org: str,
        name: str,
    ) -> Mapping[str, Any]:
        upstream = self.get_repository(upstream_owner, name)
        if upstream is None or upstream.get("full_name") != f"{upstream_owner}/{name}":
            raise ForkChainError(f"canonical repository {upstream_owner}/{name} does not exist")
        if upstream.get("fork") is True:
            raise ForkChainError("the canonical repository must be the non-fork source")

        root = f"{upstream_owner}/{name}"
        osp = self.ensure_fork(
            source_owner=upstream_owner,
            destination_org=osp_org,
            name=name,
            expected_root=root,
        )
        # Create the OOC leg from the OSP fork, not directly from the source.
        ooc = self.ensure_fork(
            source_owner=osp_org,
            destination_org=ooc_org,
            name=name,
            expected_root=root,
        )
        return {
            "upstream": root,
            "osp": osp,
            "ooc": ooc,
            "chain": [root, f"{osp_org}/{name}", f"{ooc_org}/{name}"],
        }


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: add-mirror-repo.sh https://github.com/OWNER/REPOSITORY", file=sys.stderr)
        return 2
    upstream_owner = os.environ.get("UPSTREAM_OWNER", "Interested-Deving-1896")
    osp_org = os.environ.get("OSP_ORG", "OpenOS-Project-OSP")
    ooc_org = os.environ.get("OOC_ORG", "OpenOS-Project-Ecosystem-OOC")
    match = re.fullmatch(r"https://github\\.com/([^/]+)/([^/]+?)(?:\\.git)?", args[0].strip().rstrip("/"))
    if not match or match.group(1) != upstream_owner:
        print(f"ERROR: URL must be https://github.com/{upstream_owner}/<repo>", file=sys.stderr)
        return 2
    name = match.group(2)
    try:
        chain = GitHubForkChain(os.environ.get("GH_TOKEN", "")).ensure_chain(
            upstream_owner=upstream_owner,
            osp_org=osp_org,
            ooc_org=ooc_org,
            name=name,
        )
    except (ForkChainError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(chain, indent=2, sort_keys=True))
    print("Fork chain provisioned. The scheduled upstream and OSP→OOC workflows maintain ongoing synchronization.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
