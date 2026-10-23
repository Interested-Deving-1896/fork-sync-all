"""Regression tests for generated trust-token deduplication."""

import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "vouch-registry.sh"


def test_generated_trust_tokens_are_deduplicated_without_losing_attribution(
    tmp_path: Path,
) -> None:
    registry = tmp_path / "vouch-registry.yml"
    output = tmp_path / "VOUCHED.td"
    registry.write_text(
        """entries:
  - handle: Interested-Deving-1896
    tier: 1
    type: individual
    role: Creator / Maintainer
    active: true
    platforms:
      github: Interested-Deving-1896
  - handle: Example-Org
    tier: 2
    type: organization
    role: Organization
    active: true
    platforms:
      gitlab: shared-handle
  - handle: Example-Project
    tier: 2
    type: project
    role: Project
    active: true
    platforms:
      gitlab: shared-handle
""",
        encoding="utf-8",
    )

    env = {
        **os.environ,
        "REGISTRY_FILE": str(registry),
        "DRY_RUN": "false",
    }
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_sync_vouched_td "$2"',
            "_",
            str(SCRIPT),
            str(output),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    generated = output.read_text(encoding="utf-8")
    tokens = [
        line.split("#", 1)[0].strip()
        for line in generated.splitlines()
        if line.strip() and not line.lstrip().startswith("#") and ":" in line
    ]

    assert tokens.count("gitlab:shared-handle") == 1
    assert "Example-Org — Organization" in generated
    assert "Example-Project — Project" in generated
    assert "github:Interested-Deving-1896" in generated
    assert "Interested-Deving-1896 — Creator / Maintainer" in generated



def test_registry_sync_preserves_existing_denouncements(tmp_path: Path) -> None:
    registry = tmp_path / "vouch-registry.yml"
    output = tmp_path / "VOUCHED.td"
    registry.write_text(
        """entries:
  - handle: Maintainer
    tier: 1
    type: individual
    role: Maintainer
    active: true
    platforms:
      github: Maintainer
""",
        encoding="utf-8",
    )
    output.write_text(
        "# Existing trust state\n"
        "github:Maintainer\n"
        "-github:blocked-user [confirmed abuse]\n",
        encoding="utf-8",
    )

    env = {
        **os.environ,
        "REGISTRY_FILE": str(registry),
        "DRY_RUN": "false",
    }
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_sync_vouched_td "$2"',
            "_",
            str(SCRIPT),
            str(output),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    generated = output.read_text(encoding="utf-8")
    assert "# Denounced" in generated
    assert "-github:blocked-user [confirmed abuse]" in generated

def test_registry_sync_preserves_policy_documentation_and_pins_creator(
    tmp_path: Path,
) -> None:
    registry = tmp_path / "vouch-registry.yml"
    output = tmp_path / "VOUCHED.td"
    registry.write_text(
        """entries:
  - handle: Interested-Deving-1896
    tier: 1
    type: individual
    role: Original Creator, Developer, Maintainer
    active: true
    platforms:
      github: Interested-Deving-1896
  - handle: Example-Contributor
    tier: 3
    type: individual
    role: Contributor
    active: true
    platforms:
      github: Example-Contributor
""",
        encoding="utf-8",
    )
    output.write_text(
        "# Old generated file\n"
        "# ── Org owner and bots (always trusted) ───────────────────────────────────────\n"
        "github:Interested-Deving-1896\n"
        "github:TrustedBot\n"
        "\n"
        "-github:blocked-user [confirmed abuse]\n",
        encoding="utf-8",
    )

    env = {
        **os.environ,
        "REGISTRY_FILE": str(registry),
        "DRY_RUN": "false",
    }
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_sync_vouched_td "$2"',
            "_",
            str(SCRIPT),
            str(output),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    generated = output.read_text(encoding="utf-8")
    tokens = [
        line.split("#", 1)[0].strip()
        for line in generated.splitlines()
        if line.strip() and not line.lstrip().startswith("#") and ":" in line
    ]

    assert "# Management:" in generated
    assert "#   denounce @user — denounce via issue comment (maintainers only)" in generated
    assert "# Sensitive-path policy (enforced by scripts/vouch-check-pr.sh):" in generated
    assert "#   Denounced authors → always auto-closed regardless of paths touched" in generated
    assert "# ── Org owner and bots (always trusted)" in generated
    assert tokens.count("github:Interested-Deving-1896") == 1
    assert tokens.count("github:TrustedBot") == 1
    assert "github:TrustedBot" in generated
    assert "github:Example-Contributor" in generated
    assert "-github:blocked-user [confirmed abuse]" in generated

def test_registry_sync_preserves_pins_across_blank_lines_and_stops_before_denouncements(
    tmp_path: Path,
) -> None:
    registry = tmp_path / "vouch-registry.yml"
    output = tmp_path / "VOUCHED.td"
    registry.write_text(
        """entries:
  - handle: Interested-Deving-1896
    tier: 1
    type: individual
    role: Creator / Maintainer
    active: true
    platforms:
      github: Interested-Deving-1896
""",
        encoding="utf-8",
    )
    output.write_text(
        "# ── Org owner and bots (always trusted) ───────────────────────────────────────\\n"
        "github:Interested-Deving-1896\\n"
        "\\n"
        "# Trusted automation accounts\\n"
        "github:TrustedBot\\n"
        "\\n"
        "# Denounced\\n"
        "-github:blocked-user [confirmed abuse]\\n",
        encoding="utf-8",
    )

    env = {
        **os.environ,
        "REGISTRY_FILE": str(registry),
        "DRY_RUN": "false",
    }
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; registry_sync_vouched_td "$2"',
            "_",
            str(SCRIPT),
            str(output),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
    generated = output.read_text(encoding="utf-8")
    assert generated.count("github:TrustedBot") == 1
    assert generated.count("-github:blocked-user [confirmed abuse]") == 1
    assert "# Denounced" in generated
    assert generated.index("# Denounced") < generated.index("-github:blocked-user")
