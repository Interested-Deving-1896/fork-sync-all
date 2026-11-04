import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "programming-language-badge-registry.py"
SPEC = importlib.util.spec_from_file_location("programming_language_badges", MODULE_PATH)
assert SPEC and SPEC.loader
REGISTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REGISTRY)


def test_registry_validates_and_renders_single_language():
    config = REGISTRY.load_config(ROOT / "config" / "programming-language-badges.json")
    rendered = REGISTRY.render(config, {"Rust": 1200})
    assert "[![Language: Rust]" in rendered
    assert "logo=rust" in rendered


def test_multiple_languages_are_deterministic_by_bytes_then_name():
    config = REGISTRY.load_config(ROOT / "config" / "programming-language-badges.json")
    data = {"Python": 10, "Rust": 30, "Shell": 30}
    rendered = REGISTRY.render(config, data)
    assert rendered.index("Language: Rust") < rendered.index("Language: Shell") < rendered.index("Language: Python")
    assert rendered == REGISTRY.render(config, dict(reversed(list(data.items()))))


def test_unknown_and_missing_language_metadata_are_explicit():
    config = REGISTRY.load_config(ROOT / "config" / "programming-language-badges.json")
    assert "Language-undetected" in REGISTRY.render(config, {})
    assert "Other%20languages" in REGISTRY.render(config, {"NovelLang": 100})


def test_gitlab_percentage_metadata_is_supported():
    normalized = REGISTRY.normalize_languages({"Rust": 75.5, "Shell": 24.5})
    assert normalized == {"Rust": 75.5, "Shell": 24.5}


def test_metadata_validation_rejects_bad_shapes_and_counts():
    for value in ([], None, {"Rust": -1}, {"Rust": True}, {"": 10}):
        try:
            REGISTRY.normalize_languages(value)
        except ValueError:
            pass
        else:
            raise AssertionError(f"expected invalid language metadata: {value!r}")


def test_strip_only_removes_managed_language_badge_rows():
    original = "# Demo\n[![Language: Rust](https://img.shields.io/badge/Rust-dea584)]\nKeep my custom badge\n"
    stripped = REGISTRY.strip_managed(original)
    assert "Language: Rust" not in stripped
    assert "Keep my custom badge" in stripped
