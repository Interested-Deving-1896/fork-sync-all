"""Tests for live-chain admission and README audit scope safety."""

from __future__ import annotations

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import json
import os
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "config" / "live-chain-manifest.json"

sys.path.insert(0, str(ROOT / "scripts"))
from live_chain_manifest import load_manifest, validate_manifest  # noqa: E402


def load_audit_module():
    path = ROOT / "scripts" / "audit-mirror-readmes.py"
    spec = spec_from_file_location("audit_mirror_readmes_admission", path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def minimal_manifest(*projects: dict[str, str]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "source": {"platform": "github", "namespace": "Source"},
        "mirrors": [
            {"platform": "github", "namespace": "Mirror-A"},
            {"platform": "github", "namespace": "Mirror-B"},
        ],
        "projects": list(projects),
    }


def test_repository_manifest_is_valid_and_matches_live_baseline() -> None:
    manifest = load_manifest(MANIFEST)
    managed = [
        item for item in manifest["projects"] if item["readme_policy"] == "managed"
    ]
    exceptions = [
        item for item in manifest["projects"] if item["readme_policy"] == "exception"
    ]

    assert len(manifest["projects"]) == 90
    assert len(managed) == 79
    assert len(exceptions) == 11


def test_duplicate_project_is_rejected() -> None:
    manifest = minimal_manifest(
        {"name": "demo", "readme_policy": "managed"},
        {"name": "demo", "readme_policy": "managed"},
    )

    assert "duplicate project: demo" in validate_manifest(manifest)


def test_exception_requires_reason() -> None:
    manifest = minimal_manifest({"name": "demo", "readme_policy": "exception"})

    assert "projects[0].reason is required for an exception" in validate_manifest(
        manifest
    )


def test_validator_emits_only_admitted_project_names(tmp_path: Path) -> None:
    path = tmp_path / "manifest.json"
    path.write_text(
        json.dumps(
            minimal_manifest(
                {"name": "alpha", "readme_policy": "managed"},
                {
                    "name": "beta",
                    "readme_policy": "exception",
                    "reason": "fixture",
                },
            )
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "validate-live-chain-manifest.py"),
            "--emit-projects",
            str(path),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["alpha", "beta"]


def test_validator_rejects_unadmitted_runtime_namespace(tmp_path: Path) -> None:
    path = tmp_path / "manifest.json"
    path.write_text(
        json.dumps(
            minimal_manifest({"name": "alpha", "readme_policy": "managed"})
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "validate-live-chain-manifest.py"),
            "--source-namespace",
            "Unexpected-Source",
            str(path),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 1
    assert "active source namespace is not admitted" in result.stderr


def test_audit_flags_unapproved_live_project() -> None:
    module = load_audit_module()
    manifest = minimal_manifest({"name": "approved", "readme_policy": "managed"})
    policy = {
        "required_headings": [],
        "required_managed_sections": [],
        "required_badge_text": "badge",
        "forbidden_text": {},
    }

    class Client:
        def repositories(self, owner: str):
            return [{"name": "approved"}, {"name": "surprise"}]

        def repository(self, owner: str, name: str):
            return {"name": name}

        def readme(self, owner: str, name: str):
            return "# Demo\n\nbadge\n"

    report = module.audit(policy, manifest, Client())

    assert report["healthy"] is False
    assert report["admission"]["unapproved_live"] == 1
    assert {
        "project": "surprise",
        "finding": (
            "unapproved live project; add it to config/live-chain-manifest.json "
            "before admitting it to the chain"
        ),
    } in report["findings"]


def test_mirror_script_has_fail_closed_admission_gate() -> None:
    script = (ROOT / "scripts" / "mirror-orgs.sh").read_text(encoding="utf-8")

    assert 'LIVE_CHAIN_MANIFEST="${LIVE_CHAIN_MANIFEST:-' in script
    assert 'load_admitted_repos "$LIVE_CHAIN_MANIFEST"' in script
    assert '${_ADMITTED[$repo]:-false}' in script
    assert "no admitted OSP-bound repositories" in script


def test_mirror_script_never_queries_unadmitted_config_project(
    tmp_path: Path,
) -> None:
    config = tmp_path / "subgroups.yml"
    config.write_text(
        "subgroups:\n  ops:\n    repos:\n      - approved\n      - surprise\n",
        encoding="utf-8",
    )
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            minimal_manifest({"name": "approved", "readme_policy": "managed"})
        ),
        encoding="utf-8",
    )
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_curl = fake_bin / "curl"
    fake_curl.write_text(
        """#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
payload = json.loads(args[args.index("-d") + 1])
query = payload["query"]
with open(os.environ["CURL_LOG"], "a", encoding="utf-8") as handle:
    handle.write(query + "\\n")
data = {}
for index, owner, name in re.findall(r'r(\\d+): repository\\(owner: "([^"]+)", name: "([^"]+)"\\)', query):
    data[f"r{index}"] = {
        "name": name,
        "diskUsage": 1,
        "defaultBranchRef": {"name": "main"},
    }
print(json.dumps({"data": data}))
""",
        encoding="utf-8",
    )
    fake_curl.chmod(0o755)
    curl_log = tmp_path / "curl.log"
    env = {
        **os.environ,
        "PATH": f"{fake_bin}{os.pathsep}{os.environ['PATH']}",
        "GH_TOKEN": "fixture-token",
        "OSP_REPOS_CONFIG": str(config),
        "LIVE_CHAIN_MANIFEST": str(manifest),
        "UPSTREAM_OWNER": "Source",
        "OSP_ORG": "Mirror-A",
        "OOC_ORG": "Mirror-B",
        "DRY_RUN": "true",
        "BUDGET_MINUTES": "0",
        "CURL_LOG": str(curl_log),
    }

    result = subprocess.run(
        ["bash", str(ROOT / "scripts" / "mirror-orgs.sh")],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Admission gate: 1 selected; 1 configured project(s) not admitted" in result.stdout
    assert "Repos to mirror: 1" in result.stdout
    queries = curl_log.read_text(encoding="utf-8")
    assert 'name: "approved"' in queries
    assert "surprise" not in queries
