"""Tests for registry-driven, fail-closed cleanup target selection."""
from __future__ import annotations

import pytest

from scripts.template_cleanup_registry import resolve_targets


def test_bare_names_route_only_to_documented_default_owner() -> None:
    targets, _ = resolve_targets(
        {"consumers": [{"name": "alpha"}, {"name": "beta"}]},
        "Interested-Deving-1896",
    )
    assert targets == [
        ("Interested-Deving-1896", "alpha"),
        ("Interested-Deving-1896", "beta"),
    ]


def test_qualified_managed_target_preserves_explicit_owner() -> None:
    targets, _ = resolve_targets(
        {"consumers": [{"name": "Example-Org/project", "tier": "managed"}]},
        "Interested-Deving-1896",
    )
    assert targets == [("Example-Org", "project")]


def test_protected_delegated_and_disabled_consumers_are_skipped() -> None:
    targets, skipped = resolve_targets(
        {"consumers": [
            {"name": "source", "tier": "protected"},
            {"name": "downstream", "tier": "delegated", "delegated_to": "owner/source"},
            {"name": "paused", "disabled": True},
            {"name": "active"},
        ]},
        "Interested-Deving-1896",
    )
    assert targets == [("Interested-Deving-1896", "active")]
    assert skipped == [
        "source: tier=protected",
        "downstream: tier=delegated",
        "paused: disabled",
    ]


def test_duplicate_canonical_targets_fail_closed() -> None:
    with pytest.raises(ValueError, match="duplicate canonical target"):
        resolve_targets(
            {"consumers": [
                {"name": "alpha"},
                {"name": "Interested-Deving-1896/alpha"},
            ]},
            "Interested-Deving-1896",
        )


@pytest.mark.parametrize("name", ["", "/repo", "owner/", "one/two/three", "bad name"])
def test_malformed_names_fail_closed(name: str) -> None:
    with pytest.raises(ValueError):
        resolve_targets({"consumers": [{"name": name}]}, "Interested-Deving-1896")


def test_invalid_tier_and_disabled_type_fail_closed() -> None:
    with pytest.raises(ValueError, match="invalid tier"):
        resolve_targets({"consumers": [{"name": "alpha", "tier": "unknown"}]}, "owner")
    with pytest.raises(ValueError, match="disabled must be boolean"):
        resolve_targets({"consumers": [{"name": "alpha", "disabled": "false"}]}, "owner")


def test_registry_without_consumers_fails_closed() -> None:
    with pytest.raises(ValueError, match="'consumers' must be a list"):
        resolve_targets({}, "owner")
