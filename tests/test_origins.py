"""Tests for the shared Origins provenance parser and validator."""
import importlib.util
from pathlib import Path

import pytest
import yaml

from origins import OriginsValidationError, load_manifest, normalize_manifest

ROOT = Path(__file__).resolve().parents[1]
VALID = {
    "influences": [{
        "source": "TraceMachina/nativelink",
        "url": "https://github.com/TraceMachina/nativelink",
        "relationship": "reference",
        "what": "Optional REAPI backend reference.",
        "artifact": "scripts/nativelink_adapter.py",
    }]
}


def test_repository_manifest_loads_and_normalizes():
    model = load_manifest(ROOT / "dep-graph/provenance.yml")
    assert any(item["source"] == "TraceMachina/nativelink" for item in model["influences"])
    assert model["influences"] == sorted(
        model["influences"], key=lambda item: item["source"].casefold()
    )


@pytest.mark.parametrize("payload, message", [
    ([], "root must be a mapping"),
    ({}, "missing required"),
    ({"influences": {}}, "must be a list"),
    ({"influences": ["bad"]}, "must be a mapping"),
    ({"influences": [{"source": "owner/repo"}]}, "url"),
    ({ "influences": [{**VALID["influences"][0], "relationship": "execute"}]}, "relationship"),
    ({ "influences": [{**VALID["influences"][0], "url": "http://github.com/TraceMachina/nativelink"}]}, "HTTPS"),
    ({ "influences": [{**VALID["influences"][0], "url": "https://github.com/other/repo"}]}, "same owner/repository"),
    ({ "influences": [{**VALID["influences"][0], "source": "TraceMachina/nativelink/extra"}]}, "owner/repository"),
    ({ "influences": [{**VALID["influences"][0], "extra": "unexpected"}]}, "unknown field"),
])
def test_invalid_manifests_fail_closed(payload, message):
    with pytest.raises(OriginsValidationError, match=message):
        normalize_manifest(payload)


def test_duplicate_sources_rejected_case_insensitively():
    entry = VALID["influences"][0]
    duplicate = {**entry, "source": "tracemachina/NATIVELINK"}
    with pytest.raises(OriginsValidationError, match="duplicates"):
        normalize_manifest({"influences": [entry, duplicate]})


def test_duplicate_yaml_keys_rejected(tmp_path):
    path = tmp_path / "duplicate.yml"
    path.write_text(
        "influences:\n"
        "  - source: owner/repo\n"
        "    source: other/repo\n"
        "    url: https://github.com/owner/repo\n"
        "    relationship: reference\n"
        "    what: test\n",
        encoding="utf-8",
    )
    with pytest.raises(OriginsValidationError, match="duplicate YAML mapping key"):
        load_manifest(path)


def test_normalization_does_not_mutate_input():
    import copy
    original = copy.deepcopy(VALID)
    normalize_manifest(original)
    assert original == VALID
