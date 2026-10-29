from __future__ import annotations

import json
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


def test_active_agent_skills_registry_is_provider_neutral() -> None:
    registry = yaml.safe_load((ROOT / "config/agent-skills.yml").read_text(encoding="utf-8"))
    assert "ona" not in registry["providers"]
    assert ".ona/skills" not in registry["policy"]["allowed_roots"]
    for skill in ("fork-sync-all-audit", "kport-audit"):
        package = ROOT / ".agents/skills" / skill / "SKILL.md"
        assert package.is_file()
        text = package.read_text(encoding="utf-8")
        assert "name:" in text.split("---", 2)[1]
        assert "Co-authored-by: Ona" not in text


def test_shared_devcontainer_does_not_forward_legacy_ona_environment() -> None:
    config = json.loads((ROOT / ".devcontainer/devcontainer.json").read_text(encoding="utf-8"))
    forwarded = config.get("remoteEnv", {})
    assert not {"ONA_TOKEN", "ONA_API", "ONA_MCP_URL"}.intersection(forwarded)


def test_devcontainer_validator_treats_ona_config_as_optional() -> None:
    source = (ROOT / "scripts/devcontainer-validate.py").read_text(encoding="utf-8")
    assert 'if path == ".ona/config.yaml":' in source
    assert 'errors.append(f"MISSING: {path}")' in source


def test_active_automation_does_not_hard_code_ona_coauthor() -> None:
    candidates = [
        *((ROOT / "scripts").glob("*.sh")),
        *((ROOT / ".github/workflows").glob("*.yml")),
        *((ROOT / ".github/workflows").glob("*.yaml")),
    ]
    for path in candidates:
        source = path.read_text(encoding="utf-8")
        assert "Co-authored-by: Ona <no-reply@ona.com>" not in source, str(path)


def test_ona_mcp_api_helpers_do_not_return_raw_exception_details() -> None:
    source = (ROOT / "scripts/ona-mcp-server.py").read_text(encoding="utf-8")
    # Guard the API boundary against accidentally reintroducing credential- or
    # URL-bearing exception strings in tool responses.
    assert 'return {"error": str(e)}' not in source
    assert 'Ona API request failed (HTTP {exc.response.status_code})' in source
    assert 'Ona API returned invalid JSON' in source
