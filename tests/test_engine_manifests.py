"""Tests for incremental engine manifest validation."""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from validate_engine_manifests import EngineManifestError, validate  # noqa: E402


def test_checked_in_engine_inventory_validates():
    engines = validate(
        ROOT / "config/engine-inventory.yml",
        ROOT / "config/engine-manifest.schema.json",
    )
    assert engines == ["nativelink-adapter", "origins-core"]


def test_unknown_origin_is_rejected(tmp_path):
    source = ROOT / "config/engine-manifests/nativelink-adapter.yml"
    content = source.read_text(encoding="utf-8").replace(
        "TraceMachina/nativelink", "unknown/project"
    )
    manifest = tmp_path / "nativelink.yml"
    manifest.write_text(content, encoding="utf-8")
    # Exercise the manifest-level resolver using the repository inventory's known
    # origin set; the public validator must reject unknown references.
    from validate_engine_manifests import validate_manifest
    known = {"tracemachina/nativelink"}
    with pytest.raises(EngineManifestError, match="unknown Origins reference"):
        validate_manifest(manifest, known)
