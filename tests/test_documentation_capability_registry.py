import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "documentation-capability-registry.py"
SPEC = importlib.util.spec_from_file_location("documentation_capability_registry", MODULE_PATH)
assert SPEC and SPEC.loader
REGISTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REGISTRY)


def config():
    return json.loads((ROOT / "config" / "documentation-capabilities.json").read_text())


def test_repository_manifest_is_valid_and_only_renders_verified_targets():
    manifest = REGISTRY.load_config()
    rendered = REGISTRY.render(manifest, "README.md")
    assert "[English](" in rendered
    assert "[mdbook](" in rendered
    assert "Read aloud" not in rendered
    assert "Braille-ready" not in rendered


def test_missing_translation_falls_back_to_verified_default():
    manifest = config()
    rendered = REGISTRY.render(manifest, "README.md", "fr-CA")
    assert "[English](" in rendered
    assert "fr-CA" not in rendered


def test_unverified_translation_is_not_rendered_and_falls_back():
    manifest = config()
    manifest["documents"]["README.md"]["translations"]["fr"] = {
        "label": "Français", "url": "https://example.test/fr", "verified": False
    }
    rendered = REGISTRY.render(manifest, "README.md", "fr")
    assert "[English](" in rendered
    assert "Français" not in rendered


def test_enabled_capability_requires_verified_https_destination():
    manifest = config()
    manifest["documents"]["README.md"]["capabilities"]["read_aloud"] = {
        "enabled": True, "verified": False, "url": "https://example.test/speak"
    }
    try:
        REGISTRY.validate(manifest)
    except ValueError as exc:
        assert "unless verified" in str(exc)
    else:
        raise AssertionError("unverified speech capability must fail closed")


def test_non_https_targets_are_rejected():
    manifest = config()
    manifest["documents"]["README.md"]["formats"]["mdbook"] = "javascript:alert(1)"
    try:
        REGISTRY.validate(manifest)
    except ValueError as exc:
        assert "HTTPS" in str(exc)
    else:
        raise AssertionError("non-HTTPS destinations must be rejected")


def test_unknown_document_is_rejected():
    try:
        REGISTRY.render(config(), "missing.md")
    except ValueError as exc:
        assert "unknown document" in str(exc)
    else:
        raise AssertionError("unknown documents must fail closed")
