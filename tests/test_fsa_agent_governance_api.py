"""Contract tests for the FSA-API agent governance route."""
import importlib.util
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ROUTES = yaml.safe_load((ROOT / "fsa-api/config/fsa-routes.yml").read_text())["routes"]
TOGGLES = yaml.safe_load((ROOT / "fsa-api/config/fsa-toggles.yml").read_text())["toggles"]


def test_agent_evidence_route_is_authenticated_read_only_and_toggle_gated():
    matches = [r for r in ROUTES if r.get("path") == "/api/fsa/governance/agent-evidence/:pr"]
    assert len(matches) == 1
    route = matches[0]
    assert route["method"] == "GET"
    assert route["auth"] is True
    assert route["toggle"] == "agent_governance"
    assert route["script"] == "core/adapters/governance/agent-evidence.sh"
    assert TOGGLES["agent_governance"]["enabled"] is True


def test_agent_evidence_adapter_exists_and_passes_shell_syntax():
    adapter = ROOT / "fsa-api/core/adapters/governance/agent-evidence.sh"
    assert adapter.is_file()
    subprocess.run(["bash", "-n", str(adapter)], check=True)


def test_fsa_cli_exposes_governance_evidence_command():
    cli = (ROOT / "fsa-api/cli/fsa.sh").read_text()
    assert "governance)" in cli
    assert "/api/fsa/governance/agent-evidence/" in cli
