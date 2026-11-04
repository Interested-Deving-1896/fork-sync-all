"""GitHub adapter for the provider-neutral mirror-chain engine.

The injected client must implement:
  get_repository(owner, name) -> mapping | None
  request_fork(source_owner, source_name, destination_org) -> mapping

A missing repository is represented only by an explicit None result (normally
an HTTP 404). Authentication, rate-limit, network, and permission errors must
be raised by the client and are never converted into "repository absent".
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

from . import (
    ProvisioningError,
    RepositoryRef,
    RepositoryState,
    Strategy,
)


class GitHubClient(Protocol):
    def get_repository(self, owner: str, name: str) -> Mapping[str, Any] | None: ...
    def request_fork(
        self, source_owner: str, source_name: str, destination_org: str
    ) -> Mapping[str, Any]: ...


class GitHubRepositoryProvider:
    """Resolve immutable GitHub IDs and create only verified native forks."""

    provider = "github"

    def __init__(self, client: GitHubClient):
        self.client = client

    @staticmethod
    def _state(payload: Mapping[str, Any], expected: RepositoryRef) -> RepositoryState:
        full_name = payload.get("full_name")
        if not isinstance(full_name, str) or "/" not in full_name:
            raise ProvisioningError("GitHub response lacks canonical full_name")
        owner, name = full_name.split("/", 1)
        repository_id = payload.get("id")
        if repository_id is None:
            raise ProvisioningError(f"GitHub response lacks immutable ID for {full_name}")
        parent = payload.get("parent") or {}
        source = payload.get("source") or {}
        return RepositoryState(
            ref=RepositoryRef(
                provider="github",
                owner=owner,
                name=name,
                repository_id=str(repository_id),
            ),
            exists=True,
            is_fork=payload.get("fork") is True,
            parent_id=str(parent["id"]) if parent.get("id") is not None else None,
            source_id=str(source["id"]) if source.get("id") is not None else None,
            archived=payload.get("archived") is True,
        )

    def resolve(self, ref: RepositoryRef) -> RepositoryState:
        if ref.provider.casefold() != self.provider:
            raise ProvisioningError(f"GitHub adapter cannot resolve {ref.provider}")
        payload = self.client.get_repository(ref.owner, ref.name)
        if payload is None:
            return RepositoryState(ref=ref, exists=False)
        # Keep the provider's canonical full_name and immutable ID. The core
        # engine compares it to the requested coordinate and fails on redirects.
        return self._state(payload, ref)

    def create_native_fork(
        self, source: RepositoryState, destination: RepositoryRef
    ) -> RepositoryState:
        if destination.provider.casefold() != self.provider:
            raise ProvisioningError("GitHub adapter cannot create a fork on another provider")
        if source.ref.repository_id is None:
            raise ProvisioningError("cannot fork a source without an immutable repository ID")
        self.client.request_fork(
            source.ref.owner, source.ref.name, destination.owner
        )
        # GitHub fork creation may be asynchronous. A missing result is not
        # success; the caller can safely retry after the provider has settled.
        result = self.resolve(destination)
        if not result.exists:
            raise ProvisioningError(
                f"GitHub accepted fork request but {destination.coordinate} is not yet visible"
            )
        return result

    def create_clone_mirror(
        self, source: RepositoryState, destination: RepositoryRef
    ) -> RepositoryState:
        raise ProvisioningError(
            "GitHub clone-mirror creation is not implemented; refusing an unsafe partial write"
        )
