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


def _same_coordinate(actual: RepositoryRef, expected: RepositoryRef) -> bool:
    return (
        actual.provider.casefold() == expected.provider.casefold()
        and actual.owner.casefold() == expected.owner.casefold()
        and actual.name.casefold() == expected.name.casefold()
    )


def _verify_existing_destination(
    source: RepositoryState,
    destination: RepositoryRef,
    current: RepositoryState,
    strategy: Strategy,
) -> None:
    if not _same_coordinate(current.ref, destination):
        raise ProvisioningError(
            f"redirect/identity conflict at {destination.coordinate}; "
            f"provider resolved {current.ref.coordinate}"
        )
    if destination.repository_id is not None and current.ref.repository_id != destination.repository_id:
        raise ProvisioningError(
            f"immutable repository ID conflict at {destination.coordinate}"
        )
    source_id = source.ref.repository_id
    if source_id is None:
        raise ProvisioningError(
            f"source immutable repository ID is unavailable for {destination.coordinate}"
        )
    if strategy is Strategy.NATIVE_FORK:
        if not current.is_fork or current.parent_id != source_id:
            raise ProvisioningError(
                f"identity/ancestry conflict at {destination.coordinate}; "
                "refusing overwrite, rename, or conversion"
            )
    else:
        if current.is_fork or current.source_id != source_id:
            raise ProvisioningError(
                f"clone-mirror identity/source conflict at {destination.coordinate}; "
                "refusing overwrite or conversion"
            )


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
                    _verify_existing_destination(source, edge.destination, current, edge.strategy)
                    action = "keep"
                    reason = "existing destination identity and strategy verified"
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
        pending = list(spec.edges)
        while pending:
            progressed = False
            for edge in pending[:]:
                source = completed.get(edge.source.coordinate)
                if source is None or not source.exists:
                    continue
                provider = self.providers[edge.destination.provider]
                current = provider.resolve(edge.destination)
                if current.exists:
                    _verify_existing_destination(source, edge.destination, current, edge.strategy)
                    completed[edge.destination.coordinate] = current
                    pending.remove(edge)
                    progressed = True
                    continue
                if edge.strategy is Strategy.NATIVE_FORK:
                    result = provider.create_native_fork(source, edge.destination)
                else:
                    result = provider.create_clone_mirror(source, edge.destination)
                if not result.exists or not _same_coordinate(result.ref, edge.destination):
                    raise ProvisioningError(
                        f"provider did not verify identity of {edge.destination.coordinate}"
                    )
                if edge.destination.repository_id is not None and result.ref.repository_id != edge.destination.repository_id:
                    raise ProvisioningError(
                        f"provider returned the wrong immutable ID for {edge.destination.coordinate}"
                    )
                _verify_existing_destination(source, edge.destination, result, edge.strategy)
                completed[edge.destination.coordinate] = result
                pending.remove(edge)
                progressed = True
            if not progressed:
                unresolved = ", ".join(edge.destination.coordinate for edge in pending)
                raise ProvisioningError(
                    "unable to apply mirror graph from verified sources: " + unresolved
                )
        return actions
