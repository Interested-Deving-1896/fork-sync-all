import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "agent-badge-registry.py"
SPEC = importlib.util.spec_from_file_location("agent_badge_registry", MODULE_PATH)
assert SPEC and SPEC.loader
REGISTRY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REGISTRY)


def test_registry_renders_universal_and_provider_badges():
    config = REGISTRY.load_config(ROOT / "config" / "ai-agent-badges.json")
    rendered = REGISTRY.render(config, "https://github.com/example/project")

    assert "AI agent ready" in rendered
    assert "Open in Codex" in rendered
    assert "Open in Claude Code" in rendered
    assert "Open in GitHub Copilot" in rendered
    assert "Open in Cursor" in rendered
    assert "Use with Gemini CLI" in rendered
    assert "ona.com" not in rendered


def test_registry_strips_current_and_legacy_badges_only():
    config = REGISTRY.load_config(ROOT / "config" / "ai-agent-badges.json")
    rendered = REGISTRY.render(config, "https://github.com/example/project")
    content = "# Demo\n" + rendered + "\n[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#repo)\nKeep me\n"

    stripped = REGISTRY.strip_managed(config, content)

    assert "AI agent ready" not in stripped
    assert "Built with Ona" not in stripped
    assert "Keep me" in stripped
