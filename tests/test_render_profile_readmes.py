"""Tests for deterministic downstream organization profile rendering."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/render-profile-readmes.py"
CONFIG = ROOT / "config/profile-readmes.yml"


def load_renderer():
    spec = spec_from_file_location("render_profile_readmes", SCRIPT)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_readme() -> str:
    return """# Source

## Current focus

Current source work with a [relative link](characters/README.md).

## Fork-Sync-All mirror chain 🪞

Source → OSP → OOC.

## Working principles

- Preserve attribution.
"""


def test_config_uses_safe_yaml_shape() -> None:
    config = yaml.safe_load(CONFIG.read_text())

    assert config["schema_version"] == 1
    assert set(config["destinations"]) == {"osp", "ooc"}
    assert "yaml.safe_load" in SCRIPT.read_text()


def test_renders_both_profiles_with_provenance_and_variants(tmp_path: Path) -> None:
    renderer = load_renderer()
    config = renderer.load_config(CONFIG)

    rendered = renderer.render_all(config, source_readme(), "abc123")

    assert set(rendered) == {"osp", "ooc"}
    osp_path, osp = rendered["osp"]
    ooc_path, ooc = rendered["ooc"]
    assert osp_path == "profile/README.md"
    assert ooc_path == "profile/README.md"
    assert "Canonical source: Interested-Deving-1896/Interested-Deving-1896@abc123" in osp
    assert "**Continuity prism**" in osp
    assert "**Mirror Keeper**" in osp
    assert "**Connection constellation**" in ooc
    assert "**Ecosystem Wayfinder**" in ooc
    assert (
        "https://github.com/Interested-Deving-1896/Interested-Deving-1896/"
        "blob/abc123/characters/README.md"
    ) in osp


def test_missing_inherited_section_is_rejected() -> None:
    renderer = load_renderer()
    config = renderer.load_config(CONFIG)
    incomplete = "# Source\n\n## Current focus\n\nOnly one section.\n"

    try:
        renderer.render_all(config, incomplete, "abc123")
    except renderer.ProfileRenderError as exc:
        assert "missing required section" in str(exc)
    else:
        raise AssertionError("missing source sections must fail rendering")


def test_cli_write_and_check_detect_drift(tmp_path: Path) -> None:
    source = tmp_path / "README.md"
    output = tmp_path / "generated"
    source.write_text(source_readme())
    command = [
        "python3",
        str(SCRIPT),
        "--config",
        str(CONFIG),
        "--source",
        str(source),
        "--source-commit",
        "abc123",
        "--output-dir",
        str(output),
    ]

    generated = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    assert generated.returncode == 0, generated.stderr

    clean = subprocess.run(
        [*command, "--check"], cwd=ROOT, capture_output=True, text=True
    )
    assert clean.returncode == 0, clean.stderr

    osp = output / "osp/profile/README.md"
    osp.write_text(osp.read_text() + "manual edit\n")
    drift = subprocess.run(
        [*command, "--check"], cwd=ROOT, capture_output=True, text=True
    )
    assert drift.returncode == 1
    assert "profile drift" in drift.stderr
