"""Contract tests for the FSA-API agent governance route."""
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


def test_agent_evidence_report_uses_completion_router_not_workflow_run():
    report_workflow = (ROOT / ".github/workflows/agent-evidence-report.yml").read_text()
    router = (ROOT / ".github/workflows/workflow-completion-router.yml").read_text()
    sync = yaml.safe_load((ROOT / "config/workflow-sync.yml").read_text())
    assert "workflow_dispatch:" in report_workflow
    assert "workflow_run:" not in report_workflow
    assert '"Validate Config"|"Agent Accountability Contract"' in router
    assert "dispatch agent-evidence-report.yml" in router
    assert any(
        item.get("workflow_file") == "agent-evidence-report.yml"
        for item in sync["github_only"]
    )
