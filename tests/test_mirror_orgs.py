"""Regression tests for config-scoped, owner-agnostic org mirroring."""

import json
import os
from pathlib import Path
import re
import subprocess

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]
MIRROR_SCRIPT = ROOT / "scripts/mirror-orgs.sh"


@pytest.fixture
def mirror_environment(tmp_path: Path) -> dict[str, str]:
    config_path = tmp_path / "gitlab-subgroups.yml"
    config_path.write_text(
        yaml.safe_dump(
            {
                "subgroups": {
                    "ops": {
                        "repos": ["profile-repo", "unrelated-repo"],
                    }
                }
            }
        )
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(
        """#!/usr/bin/env python3
import json
import os
import re
import sys

args = sys.argv[1:]
payload = json.loads(args[args.index("-d") + 1])
query = payload["query"]
with open(os.environ["CURL_LOG"], "a") as handle:
    handle.write(query + "\\n")

data = {}
pattern = r'r(\\d+): repository\\(owner: "([^"]+)", name: "([^"]+)"\\)'
for index, owner, name in re.findall(pattern, query):
    alias = f"r{index}"
    if owner == os.environ["UPSTREAM_OWNER"] and os.environ.get("MISSING_SOURCE") == "true":
        data[alias] = None
    else:
        data[alias] = {"name": name, "diskUsage": 123}
print(json.dumps({"data": data}))
"""
    )
    fake_curl.chmod(0o755)

    curl_log = tmp_path / "curl.log"
    return {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "GH_TOKEN": "test-token",
        "OSP_REPOS_CONFIG": str(config_path),
        "OSP_ORG": "Test-OSP",
        "OOC_ORG": "Test-OOC",
        "REPO_FILTER": "profile-repo",
        "DRY_RUN": "true",
        "BUDGET_MINUTES": "0",
        "CURL_LOG": str(curl_log),
    }


def run_mirror(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(MIRROR_SCRIPT)],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize("owner", ["ExampleUser", "ExampleOrg"])
def test_exact_lookup_supports_user_and_org_owners(
    mirror_environment: dict[str, str], owner: str
) -> None:
    env = {**mirror_environment, "UPSTREAM_OWNER": owner}

    result = run_mirror(env)

    assert result.returncode == 0, result.stderr
    assert "Repos to mirror: 1" in result.stdout
    queries = Path(env["CURL_LOG"]).read_text()
    assert f'repository(owner: "{owner}", name: "profile-repo")' in queries
    assert "unrelated-repo" not in queries
    assert "organization(" not in queries
    assert "repositories(" not in queries


def test_zero_config_matches_fails_before_api_lookup(
    mirror_environment: dict[str, str],
) -> None:
    env = {
        **mirror_environment,
        "UPSTREAM_OWNER": "ExampleUser",
        "REPO_FILTER": "not-configured",
    }

    result = run_mirror(env)

    assert result.returncode != 0
    assert "no configured OSP-bound repositories matched" in result.stderr
    assert not Path(env["CURL_LOG"]).exists()


def test_zero_existing_source_repos_fails_instead_of_reporting_success(
    mirror_environment: dict[str, str],
) -> None:
    env = {
        **mirror_environment,
        "UPSTREAM_OWNER": "ExampleUser",
        "MISSING_SOURCE": "true",
    }

    result = run_mirror(env)

    assert result.returncode != 0
    assert "configured source repository not found" in result.stderr
    assert "none of the configured OSP-bound repositories exist" in result.stderr
    assert "Repos to mirror: 0" not in result.stdout


def test_registry_loader_uses_yaml_safe_load() -> None:
    script = MIRROR_SCRIPT.read_text()

    assert "yaml.safe_load" in script
    assert not re.search(r"organization\(login:", script)
