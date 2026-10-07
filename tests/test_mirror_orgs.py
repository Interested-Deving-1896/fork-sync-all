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
    manifest_path = tmp_path / "live-chain-manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "source": {"platform": "github", "namespace": "ExampleUser"},
                "mirrors": [
                    {"platform": "github", "namespace": "Test-OSP"},
                    {"platform": "github", "namespace": "Test-OOC"},
                ],
                "projects": [
                    {"name": "profile-repo", "readme_policy": "managed"},
                    {"name": "unrelated-repo", "readme_policy": "managed"},
                ],
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
errors = []
pattern = r'r(\\d+): repository\\(owner: "([^"]+)", name: "([^"]+)"\\)'
for index, owner, name in re.findall(pattern, query):
    alias = f"r{index}"
    if owner == os.environ["UPSTREAM_OWNER"] and os.environ.get("MISSING_SOURCE") == "true":
        data[alias] = None
    elif owner != os.environ["UPSTREAM_OWNER"] and os.environ.get("MISSING_DESTINATION") == "true":
        data[alias] = None
        errors.append({
            "type": "NOT_FOUND",
            "path": [alias],
            "message": f"Could not resolve destination {owner}/{name}",
        })
    else:
        data[alias] = {
            "name": name,
            "diskUsage": 123,
            "defaultBranchRef": {"name": "main"},
        }
response = {"data": data}
if errors:
    response["errors"] = errors
print(json.dumps(response))
"""
    )
    fake_curl.chmod(0o755)

    curl_log = tmp_path / "curl.log"
    return {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "GH_TOKEN": "test-token",
        "OSP_REPOS_CONFIG": str(config_path),
        "LIVE_CHAIN_MANIFEST": str(manifest_path),
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


@pytest.fixture
def writable_mirror_environment(tmp_path: Path) -> dict[str, str]:
    """Run the complete mirror path against deterministic fake git/API clients."""
    config_path = tmp_path / "gitlab-subgroups.yml"
    config_path.write_text(
        yaml.safe_dump({"subgroups": {"ops": {"repos": ["profile-repo"]}}})
    )
    manifest_path = tmp_path / "live-chain-manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "source": {"platform": "github", "namespace": "ExampleUser"},
                "mirrors": [
                    {"platform": "github", "namespace": "Test-OSP"},
                    {"platform": "github", "namespace": "Test-OOC"},
                ],
                "projects": [
                    {"name": "profile-repo", "readme_policy": "managed"}
                ],
            }
        )
    )

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(
        r'''#!/usr/bin/env python3
import base64
import json
import os
import re
import sys

args = sys.argv[1:]
method = args[args.index("-X") + 1] if "-X" in args else "GET"
url = next((arg for arg in reversed(args) if arg.startswith("https://")), "")
payload = args[args.index("-d") + 1] if "-d" in args else ""

with open(os.environ["CURL_LOG"], "a") as handle:
    handle.write(json.dumps({"method": method, "url": url, "payload": payload}) + "\n")

if url.endswith("/graphql"):
    query = json.loads(payload)["query"]
    data = {}
    pattern = r'r(\d+): repository\(owner: "([^"]+)", name: "([^"]+)"\)'
    for index, owner, name in re.findall(pattern, query):
        data[f"r{index}"] = {
            "name": name,
            "diskUsage": 123,
            "defaultBranchRef": {"name": os.environ["SOURCE_DEFAULT_BRANCH"]},
        }
    print(json.dumps({"data": data}))
    raise SystemExit(0)

source_slug = f'/repos/{os.environ["UPSTREAM_OWNER"]}/profile-repo/'
dest_slug = f'/repos/{os.environ["OSP_ORG"]}/profile-repo/'
canonical = base64.b64encode(b"# Canonical profile\n").decode()
downstream = base64.b64encode(b"# Downstream profile\n").decode()

body = {}
code = 200
if source_slug + "contents/README.md" in url:
    body = {"content": canonical}
elif dest_slug + "contents/README.md" in url and method == "GET":
    body = {"content": downstream, "sha": "dest-readme-sha"}
elif dest_slug + "git/ref/heads/" in url:
    body = {"object": {"sha": "dest-head-sha"}}
elif url.endswith("/git/refs") and method == "POST":
    body, code = {"ref": "created"}, 201
elif url.endswith("/contents/README.md") and method == "PUT":
    body = {"commit": {"sha": "readme-commit"}}
elif url.endswith("/pulls") and method == "POST":
    body, code = {"number": 17, "html_url": "https://example.test/pull/17"}, 201
elif url.endswith("/pulls/17/merge") and method == "PUT":
    if os.environ.get("PR_MERGE_SUCCESS", "true") == "true":
        body = {"merged": True}
    else:
        body, code = {"merged": False, "message": "review required"}, 405
elif url.endswith("/repos/" + os.environ["OSP_ORG"] + "/profile-repo") and method == "PATCH":
    body = {"default_branch": os.environ["SOURCE_DEFAULT_BRANCH"]}
else:
    body, code = {"message": f"unexpected fake request: {method} {url}"}, 500

print(json.dumps(body))
print(code)
'''
    )
    fake_curl.chmod(0o755)

    fake_git = fake_bin / "git"
    fake_git.write_text(
        r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["GIT_LOG"], "a") as handle:
    handle.write(json.dumps(args) + "\n")

if args and args[0] == "clone":
    raise SystemExit(0)
if "show-ref" in args:
    raise SystemExit(0)
if "push" in args:
    if os.environ.get("GIT_SCENARIO") == "protected":
        raise SystemExit(1)
    raise SystemExit(0)
raise SystemExit(0)
'''
    )
    fake_git.chmod(0o755)

    return {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "GH_TOKEN": "test-token",
        "OSP_REPOS_CONFIG": str(config_path),
        "LIVE_CHAIN_MANIFEST": str(manifest_path),
        "UPSTREAM_OWNER": "ExampleUser",
        "OSP_ORG": "Test-OSP",
        "OOC_ORG": "SKIP",
        "REPO_FILTER": "profile-repo",
        "DRY_RUN": "false",
        "BUDGET_MINUTES": "0",
        "SOURCE_DEFAULT_BRANCH": "stable/v2",
        "GITHUB_RUN_ID": "4242",
        "CURL_LOG": str(tmp_path / "curl.log"),
        "GIT_LOG": str(tmp_path / "git.log"),
    }


def read_json_lines(path: str) -> list[object]:
    return [json.loads(line) for line in Path(path).read_text().splitlines()]


@pytest.mark.parametrize("owner", ["ExampleUser", "ExampleOrg"])
def test_exact_lookup_supports_user_and_org_owners(
    mirror_environment: dict[str, str], owner: str
) -> None:
    env = {**mirror_environment, "UPSTREAM_OWNER": owner}
    manifest_path = Path(env["LIVE_CHAIN_MANIFEST"])
    manifest = json.loads(manifest_path.read_text())
    manifest["source"]["namespace"] = owner
    manifest_path.write_text(json.dumps(manifest))

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
    assert "no admitted OSP-bound repositories matched" in result.stderr
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


def test_missing_destination_is_created_instead_of_failing_graphql_batch(
    mirror_environment: dict[str, str],
) -> None:
    env = {
        **mirror_environment,
        "UPSTREAM_OWNER": "ExampleUser",
        "MISSING_DESTINATION": "true",
    }

    result = run_mirror(env)

    assert result.returncode == 0, result.stderr
    assert "Creating Test-OSP/profile-repo" in result.stdout
    assert "Creating Test-OOC/profile-repo" in result.stdout
    assert "set Test-OSP/profile-repo default branch to main" in result.stdout


def test_successful_mirror_aligns_destination_default_branch(
    writable_mirror_environment: dict[str, str],
) -> None:
    result = run_mirror(writable_mirror_environment)

    assert result.returncode == 0, result.stderr
    assert "Done: 1 mirrors pushed, 0 oversized skipped, 0 failed" in result.stdout
    requests = read_json_lines(writable_mirror_environment["CURL_LOG"])
    patches = [
        request
        for request in requests
        if request["method"] == "PATCH"
        and request["url"].endswith("/repos/Test-OSP/profile-repo")
    ]
    assert len(patches) == 1
    assert json.loads(patches[0]["payload"]) == {"default_branch": "stable/v2"}

    git_calls = read_json_lines(writable_mirror_environment["GIT_LOG"])
    assert any("--mirror" in call for call in git_calls)
    assert not any("show-ref" in call for call in git_calls)


def test_protected_branch_fallback_opens_merges_readme_pr_then_aligns_default(
    writable_mirror_environment: dict[str, str],
) -> None:
    env = {**writable_mirror_environment, "GIT_SCENARIO": "protected"}

    result = run_mirror(env)

    assert result.returncode == 0, result.stderr
    assert "README synchronized via https://example.test/pull/17" in result.stdout
    assert "Done: 1 mirrors pushed, 0 oversized skipped, 0 failed" in result.stdout
    assert "retrying protected default branch without force" in result.stderr
    assert "trying README-only PR fallback" in result.stderr

    git_calls = read_json_lines(env["GIT_LOG"])
    assert any("--mirror" in call for call in git_calls)
    assert any(
        "refs/heads/stable/v2:refs/heads/stable/v2" in call for call in git_calls
    )
    assert any("show-ref" in call and "refs/heads/stable/v2" in call for call in git_calls)

    requests = read_json_lines(env["CURL_LOG"])
    writes = [request for request in requests if request["method"] != "GET"]

    create_ref = next(request for request in writes if request["url"].endswith("/git/refs"))
    assert json.loads(create_ref["payload"]) == {
        "ref": "refs/heads/readme-mirror-sync-4242",
        "sha": "dest-head-sha",
    }

    readme_put = next(
        request for request in writes if request["url"].endswith("/contents/README.md")
    )
    readme_payload = json.loads(readme_put["payload"])
    assert readme_payload["branch"] == "readme-mirror-sync-4242"
    assert readme_payload["sha"] == "dest-readme-sha"

    pr_create = next(request for request in writes if request["url"].endswith("/pulls"))
    assert json.loads(pr_create["payload"]) == {
        "title": "docs: sync canonical README",
        "head": "readme-mirror-sync-4242",
        "base": "stable/v2",
        "body": (
            "README-only fallback for ExampleUser/profile-repo; preserves "
            "protected-branch and downstream-only history."
        ),
    }

    merge = next(request for request in writes if request["url"].endswith("/pulls/17/merge"))
    assert json.loads(merge["payload"])["merge_method"] == "squash"
    assert writes[-1]["method"] == "PATCH"
    assert json.loads(writes[-1]["payload"]) == {"default_branch": "stable/v2"}


def test_unmerged_readme_fallback_reports_failure_without_default_branch_patch(
    writable_mirror_environment: dict[str, str],
) -> None:
    env = {
        **writable_mirror_environment,
        "GIT_SCENARIO": "protected",
        "PR_MERGE_SUCCESS": "false",
    }

    result = run_mirror(env)

    assert result.returncode != 0
    assert "README fallback PR requires review: https://example.test/pull/17" in result.stderr
    assert "Done: 0 mirrors pushed, 0 oversized skipped, 1 failed" in result.stdout
    requests = read_json_lines(env["CURL_LOG"])
    assert not any(request["method"] == "PATCH" for request in requests)


def test_registry_loader_uses_yaml_safe_load() -> None:
    script = MIRROR_SCRIPT.read_text()

    assert "yaml.safe_load" in script
    assert not re.search(r"organization\(login:", script)
