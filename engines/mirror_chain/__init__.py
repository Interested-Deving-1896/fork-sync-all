"""Provider-neutral desired-state model for repository mirror chains.

This module deliberately separates repository identity from mutable owner/name
coordinates. Provider adapters must resolve a coordinate to an immutable ID and
return verified ancestry before any write is attempted.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable, Mapping, Protocol


class ProvisioningError(RuntimeError):
    """The desired mirror state cannot be reached safely."""


class Strategy(str, Enum):
    NATIVE_FORK = "native_fork"
    CLONE_MIRROR = "clone_mirror"


@dataclass(frozen=True)
class RepositoryRef:
    provider: str
    owner: str
    name: str
    repository_id: str | None = None

    @property
    def coordinate(self) -> str:
        return f"{self.provider}:{self.owner}/{self.name}"


@dataclass(frozen=True)
class RepositoryState:
    ref: RepositoryRef
    exists: bool
    is_fork: bool = False
    parent_id: str | None = None
    source_id: str | None = None
    archived: bool = False


@dataclass(frozen=True)
class ChainEdge:
    source: RepositoryRef
    destination: RepositoryRef
    strategy: Strategy = Strategy.NATIVE_FORK


@dataclass(frozen=True)
class ChainSpec:
    canonical: RepositoryRef
    edges: tuple[ChainEdge, ...]

    def validate(self) -> None:
        seen_destinations: set[str] = set()
        duplicate_destinations: set[str] = set()
        adjacency: dict[str, list[str]] = {}
        for edge in self.edges:
            source = edge.source.coordinate
            destination = edge.destination.coordinate
            if source == destination:
                raise ProvisioningError("a repository cannot mirror itself")
            if destination in seen_destinations:
                duplicate_destinations.add(destination)
            seen_destinations.add(destination)
            adjacency.setdefault(source, []).append(destination)

        # Detect cycles before reporting duplicate destinations: a back-edge
        # can be both a duplicate target and the more important graph cycle.
        # Every edge must be reachable from the canonical node.
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(node: str) -> None:
            if node in visiting:
                raise ProvisioningError(f"mirror graph contains a cycle at {node}")
            if node in visited:
                return
            visiting.add(node)
            for child in adjacency.get(node, []):
                visit(child)
            visiting.remove(node)
            visited.add(node)

        visit(self.canonical.coordinate)
        unreachable = seen_destinations - visited
        if unreachable:
            raise ProvisioningError(
                "mirror destinations are not reachable from canonical: "
                + ", ".join(sorted(unreachable))
            )
        if duplicate_destinations:
            raise ProvisioningError(
                "duplicate destination: " + ", ".join(sorted(duplicate_destinations))
            )


class RepositoryProvider(Protocol):
    """Provider adapter contract. Implementations must not hide identity errors."""

    def resolve(self, ref: RepositoryRef) -> RepositoryState: ...
    def create_native_fork(
        self, source: RepositoryState, destination: RepositoryRef
    ) -> RepositoryState: ...
    def create_clone_mirror(
        self, source: RepositoryState, destination: RepositoryRef
    ) -> RepositoryState: ...


@dataclass(frozen=True)
class PlannedAction:
    action: str
    source: str
    destination: str
    reason: str


@dataclass
class Provisioner:
    providers: Mapping[str, RepositoryProvider]
    audit: list[PlannedAction] = field(default_factory=list)

    def plan(self, spec: ChainSpec) -> list[PlannedAction]:
        spec.validate()
        states: dict[str, RepositoryState] = {
            spec.canonical.coordinate:
                self.providers[spec.canonical.provider].resolve(spec.canonical)
        }
        if not states[spec.canonical.coordinate].exists:
            raise ProvisioningError("canonical repository does not exist")
        actions: list[PlannedAction] = []
        pending = list(spec.edges)
        while pending:
            progressed = False
            for edge in pending[:]:
                source_key = edge.source.coordinate
                if source_key not in states:
                    continue
                provider = self.providers[edge.destination.provider]
                current = provider.resolve(edge.destination)
                if current.exists:
                    source = states[source_key]
                    expected_id = source.ref.repository_id
                    actual_parent = current.parent_id or current.source_id
                    if not current.is_fork or (
                        edge.strategy is Strategy.NATIVE_FORK
                        and expected_id is not None
                        and actual_parent != expected_id
                    ):
                        raise ProvisioningError(
                            f"identity/ancestry conflict at {edge.destination.coordinate}; "
                            "refusing overwrite, rename, or conversion"
                        )
                    action = "keep"
                    reason = "existing destination identity and ancestry verified"
                else:
                    action = "create"
                    reason = f"destination absent; strategy={edge.strategy.value}"
                actions.append(PlannedAction(
                    action, source_key, edge.destination.coordinate, reason
                ))
                # A missing intermediate node is represented as planned but
                # cannot be used as a verified source for a downstream edge.
                if current.exists:
                    states[edge.destination.coordinate] = current
                else:
                    # A planned intermediate node can order later edges, but
                    # carries no immutable ID until creation is verified.
                    states[edge.destination.coordinate] = RepositoryState(
                        edge.destination, exists=True
                    )
                pending.remove(edge)
                progressed = True
            if not progressed:
                raise ProvisioningError("unable to order mirror graph from canonical")
        self.audit = actions
        return actions

    def apply(self, spec: ChainSpec, *, dry_run: bool = True) -> list[PlannedAction]:
        actions = self.plan(spec)
        if dry_run:
            return actions
        # Re-resolve immediately before each write. This is the TOCTOU guard:
        # a destination created/renamed after planning must fail closed.
        completed: dict[str, RepositoryState] = {
            spec.canonical.coordinate:
                self.providers[spec.canonical.provider].resolve(spec.canonical)
        }
        for edge in spec.edges:
            source = completed.get(edge.source.coordinate)
            if source is None or not source.exists:
                raise ProvisioningError(
                    f"source {edge.source.coordinate} is not verified; "
                    "cannot provision descendants"
                )
            provider = self.providers[edge.destination.provider]
            current = provider.resolve(edge.destination)
            if current.exists:
                expected = source.ref.repository_id
                actual = current.parent_id or current.source_id
                if not current.is_fork or (
                    edge.strategy is Strategy.NATIVE_FORK
                    and expected is not None and actual != expected
                ):
                    raise ProvisioningError(
                        f"identity/ancestry changed at {edge.destination.coordinate}"
                    )
                completed[edge.destination.coordinate] = current
                continue
            if edge.strategy is Strategy.NATIVE_FORK:
                result = provider.create_native_fork(source, edge.destination)
            else:
                result = provider.create_clone_mirror(source, edge.destination)
            verified_identity = result.ref.coordinate == edge.destination.coordinate
            if edge.strategy is Strategy.NATIVE_FORK:
                expected_parent = source.ref.repository_id
                actual_parent = result.parent_id or result.source_id
                verified_strategy = result.is_fork and (
                    expected_parent is None or actual_parent == expected_parent
                )
            else:
                verified_strategy = (
                    not result.is_fork
                    and source.ref.repository_id is not None
                    and result.source_id == source.ref.repository_id
                )
            if not result.exists or not verified_identity or not verified_strategy:
                raise ProvisioningError(
                    f"provider did not verify creation of {edge.destination.coordinate}"
                )
            completed[edge.destination.coordinate] = result
        return actions
