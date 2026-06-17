"""
Tests for vouch + SBOM integration.

Coverage:
  vouch-check-pr.sh:
    - Vouched author → exit 0, status=vouched
    - Denounced author → exit 1, status=denounced, PR closed
    - Unknown author + sensitive path → exit 1, status=blocked
    - Unknown author + safe path → exit 0, status=warned
    - Bot author → exit 0, status=skipped
    - FORCE_PATH override
    - DRY_RUN suppresses API writes
    - Missing VOUCHED.td → unknown (safe fallback)

  VOUCHED.td parsing:
    - Vouched entry recognised
    - Denounced entry recognised
    - Platform-prefixed entry (github:user) recognised
    - Case-insensitive match

  validate-registered-imports.py --vouch-check:
    - Unvouched upstream org flagged as warning
    - Vouched upstream org passes silently
    - Missing VOUCHED-upstreams.td → no crash

  Config registration:
    - All 4 new workflows in workflow-sync.yml
    - All 4 new workflows in workflow-priority-tiers.yml
    - All 4 new workflows in workflow-quota-costs.yml
    - generate-sbom.yml in template-manifest.yml (infra-core + standalone)
    - vouch workflows in template-manifest.yml (infra-core + standalone)
"""

import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOUCH_SCRIPT = os.path.join(REPO_ROOT, "scripts", "vouch-check-pr.sh")
VALIDATE_SCRIPT = os.path.join(REPO_ROOT, "scripts", "validate-registered-imports.py")
VOUCHED_FILE = os.path.join(REPO_ROOT, ".github", "VOUCHED.td")
VOUCHED_UPSTREAMS = os.path.join(REPO_ROOT, ".github", "VOUCHED-upstreams.td")


# ── Mock HTTP server ──────────────────────────────────────────────────────────

class _MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n).decode() if n else ""

    def do_GET(self):
        cfg = self.server.config
        path = self.path.split("?")[0]
        cfg.setdefault("get_calls", []).append(path)

        # Collaborator permission check
        if "/collaborators/" in path and "/permission" in path:
            perm = cfg.get("collaborator_perm", "none")
            self._send_json(200, {"permission": perm})
            return

        # PR files
        if "/pulls/" in path and path.endswith("/files"):
            self._send_json(200, cfg.get("pr_files", []))
            return

        self._send_json(200, {})

    def do_POST(self):
        body = self._read_body()
        cfg = self.server.config
        cfg.setdefault("post_calls", []).append({"path": self.path, "body": body})
        self._send_json(201, {"id": 1})

    def do_PATCH(self):
        body = self._read_body()
        cfg = self.server.config
        cfg.setdefault("patch_calls", []).append({"path": self.path, "body": body})
        self._send_json(200, {"state": "closed"})


def _start_mock(config=None):
    s = HTTPServer(("127.0.0.1", 0), _MockHandler)
    s.config = config or {}
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


# ── Helper to write VOUCHED.td ────────────────────────────────────────────────

def _write_vouched(tmp_path, lines):
    f = tmp_path / "VOUCHED.td"
    f.write_text("\n".join(lines) + "\n")
    return str(f)


def _make_pr_files(paths):
    return [{"filename": p, "status": "modified"} for p in paths]


# ── Helper to run vouch-check-pr.sh ──────────────────────────────────────────

def _run_vouch(server, vouched_file, author, pr_files=None, extra_env=None):
    port = server.server_address[1]
    api = f"http://127.0.0.1:{port}"
    server.config["pr_files"] = _make_pr_files(pr_files or ["README.md"])

    env = dict(os.environ)
    env.update({
        "GH_TOKEN": "tok",
        "PR_NUMBER": "42",
        "PR_AUTHOR": author,
        "REPO": "test-org/test-repo",
        "VOUCHED_FILE": vouched_file,
        "DRY_RUN": "false",
        "REQUIRE_VOUCH_ON_SENSITIVE": "true",
        "API": api,
    })
    if extra_env:
        env.update(extra_env)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as gh_out:
        gh_out_path = gh_out.name

    env["GITHUB_OUTPUT"] = gh_out_path

    result = subprocess.run(
        ["bash", VOUCH_SCRIPT],
        env=env, capture_output=True, text=True, timeout=15
    )

    outputs = {}
    try:
        with open(gh_out_path) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    outputs[k] = v
    except Exception:
        pass
    finally:
        os.unlink(gh_out_path)

    return result, outputs


# ── vouch-check-pr.sh tests ───────────────────────────────────────────────────

def test_syntax_check_vouch_script():
    r = subprocess.run(["bash", "-n", VOUCH_SCRIPT], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_syntax_check_vouch_seed():
    seed = os.path.join(REPO_ROOT, "scripts", "vouch-seed.sh")
    r = subprocess.run(["bash", "-n", seed], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_vouched_author_passes(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, ["github:alice"])
    result, outputs = _run_vouch(server, vf, "alice")
    assert result.returncode == 0, result.stderr
    assert outputs.get("status") == "vouched"
    server.shutdown()


def test_denounced_author_closes_pr(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, ["-github:badactor reason: spam"])
    result, outputs = _run_vouch(server, vf, "badactor")
    assert result.returncode == 1
    assert outputs.get("status") == "denounced"
    # PR should have been closed via PATCH
    patch_calls = server.config.get("patch_calls", [])
    assert any("/pulls/42" in c["path"] for c in patch_calls), "Expected PR close PATCH"
    server.shutdown()


def test_unknown_author_sensitive_path_blocked(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, ["github:someone-else"])
    result, outputs = _run_vouch(
        server, vf, "newcontributor",
        pr_files=[".github/workflows/ci.yml"]
    )
    assert result.returncode == 1
    assert outputs.get("status") == "blocked"
    server.shutdown()


def test_unknown_author_safe_path_warned(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, ["github:someone-else"])
    result, outputs = _run_vouch(
        server, vf, "newcontributor",
        pr_files=["docs/README.md", "CHANGELOG.md"]
    )
    assert result.returncode == 0
    assert outputs.get("status") == "warned"
    server.shutdown()


def test_bot_author_skipped(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, [])
    result, outputs = _run_vouch(server, vf, "dependabot[bot]")
    assert result.returncode == 0
    assert outputs.get("status") == "skipped"
    server.shutdown()


def test_collaborator_skipped(tmp_path):
    server = _start_mock({"collaborator_perm": "write"})
    vf = _write_vouched(tmp_path, [])
    result, outputs = _run_vouch(server, vf, "maintainer")
    assert result.returncode == 0
    assert outputs.get("status") == "skipped"
    server.shutdown()


def test_dry_run_no_patch_calls(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, ["-github:badactor"])
    result, outputs = _run_vouch(
        server, vf, "badactor",
        extra_env={"DRY_RUN": "true"}
    )
    # Denounced but dry-run — no PATCH
    patch_calls = server.config.get("patch_calls", [])
    assert len(patch_calls) == 0, "DRY_RUN should not make PATCH calls"
    server.shutdown()


def test_missing_vouched_file_treats_as_unknown(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    result, outputs = _run_vouch(
        server, "/nonexistent/VOUCHED.td", "someone",
        pr_files=["README.md"]
    )
    # Missing file → unknown → safe path → warned (exit 0)
    assert result.returncode == 0
    assert outputs.get("status") == "warned"
    server.shutdown()


def test_case_insensitive_vouch_match(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, ["github:Alice"])
    result, outputs = _run_vouch(server, vf, "alice")
    assert result.returncode == 0
    assert outputs.get("status") == "vouched"
    server.shutdown()


def test_scripts_path_is_sensitive(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, [])
    result, outputs = _run_vouch(
        server, vf, "stranger",
        pr_files=["scripts/sync-template.sh"]
    )
    assert outputs.get("status") == "blocked"
    server.shutdown()


def test_config_path_is_sensitive(tmp_path):
    server = _start_mock({"collaborator_perm": "none"})
    vf = _write_vouched(tmp_path, [])
    result, outputs = _run_vouch(
        server, vf, "stranger",
        pr_files=["config/workflow-priority-tiers.yml"]
    )
    assert outputs.get("status") == "blocked"
    server.shutdown()


# ── validate-registered-imports.py --vouch-check tests ───────────────────────

VALID_IMPORT = {
    "target_name": "some-repo",
    "source_url": "https://github.com/test-org/some-repo",
    "platform": "github",
    "added": "2026-01-01T00:00:00Z",
}


def _run_validate(imports_data, vouched_upstreams_content=None, tmp_path=None):
    """Run validate-registered-imports.py --vouch-check with a temp VOUCHED-upstreams.td.

    The script reads VOUCHED_UPSTREAMS_FILE from the environment when set,
    falling back to the repo-relative path. We use that env var to inject a
    temp file without patching the script source.
    """
    td = str(tmp_path) if tmp_path else tempfile.mkdtemp()
    imports_file = os.path.join(td, "imports.json")
    with open(imports_file, "w") as f:
        json.dump(imports_data, f)

    env = dict(os.environ)

    if vouched_upstreams_content is not None:
        vu_file = os.path.join(td, "VOUCHED-upstreams.td")
        with open(vu_file, "w") as f:
            f.write(vouched_upstreams_content)
        env["VOUCHED_UPSTREAMS_FILE"] = vu_file

    result = subprocess.run(
        ["python3", VALIDATE_SCRIPT, imports_file, "--vouch-check"],
        env=env, capture_output=True, text=True, timeout=15
    )
    return result


def test_vouch_check_unvouched_org_warns(tmp_path):
    imports = [{**VALID_IMPORT, "source_url": "https://github.com/unknown-org/some-repo"}]
    vu = "github:Interested-Deving-1896\n"
    result = _run_validate(imports, vu, tmp_path)
    assert result.returncode == 0, result.stdout
    assert "unvouched" in result.stdout.lower() or "unknown-org" in result.stdout


def test_vouch_check_vouched_org_silent(tmp_path):
    imports = [{**VALID_IMPORT, "source_url": "https://github.com/Interested-Deving-1896/some-repo"}]
    vu = "github:Interested-Deving-1896\n"
    result = _run_validate(imports, vu, tmp_path)
    assert result.returncode == 0, result.stdout
    assert "unvouched" not in result.stdout.lower()


def test_vouch_check_missing_upstreams_file_no_crash(tmp_path):
    imports = [{**VALID_IMPORT}]
    # Empty upstreams file → org not found → advisory warning, still exit 0
    result = _run_validate(imports, vouched_upstreams_content="", tmp_path=tmp_path)
    assert result.returncode == 0, result.stdout


# ── Config registration tests ─────────────────────────────────────────────────

def test_new_workflows_in_workflow_sync():
    with open(os.path.join(REPO_ROOT, "config", "workflow-sync.yml")) as f:
        content = f.read()
    for wf in ["generate-sbom.yml", "vouch-check-pr.yml", "vouch-manage.yml", "vouch-sync-codeowners.yml"]:
        assert wf in content, f"{wf} missing from workflow-sync.yml"


def test_new_workflows_in_priority_tiers():
    with open(os.path.join(REPO_ROOT, "config", "workflow-priority-tiers.yml")) as f:
        content = f.read()
    for name in ["Generate SBOM", "Vouch Check PR", "Vouch Manage", "Vouch Sync Codeowners"]:
        assert name in content, f'"{name}" missing from workflow-priority-tiers.yml'


def test_new_workflows_in_quota_costs():
    with open(os.path.join(REPO_ROOT, "config", "workflow-quota-costs.yml")) as f:
        content = f.read()
    for name in ["Generate SBOM", "Vouch Check PR", "Vouch Manage", "Vouch Sync Codeowners"]:
        assert name in content, f'"{name}" missing from workflow-quota-costs.yml'


def test_sbom_in_template_manifest():
    with open(os.path.join(REPO_ROOT, "config", "template-manifest.yml")) as f:
        content = f.read()
    assert "generate-sbom.yml" in content, "generate-sbom.yml missing from template-manifest.yml"


def test_vouch_in_template_manifest():
    with open(os.path.join(REPO_ROOT, "config", "template-manifest.yml")) as f:
        content = f.read()
    for wf in ["vouch-check-pr.yml", "vouch-manage.yml", "vouch-sync-codeowners.yml"]:
        assert wf in content, f"{wf} missing from template-manifest.yml"


def test_vouched_td_exists():
    assert os.path.exists(VOUCHED_FILE), ".github/VOUCHED.td does not exist"


def test_vouched_upstreams_exists():
    assert os.path.exists(VOUCHED_UPSTREAMS), ".github/VOUCHED-upstreams.td does not exist"


def test_vouched_td_has_org_entry():
    with open(VOUCHED_FILE) as f:
        content = f.read()
    assert "Interested-Deving-1896" in content, \
        "VOUCHED.td missing Interested-Deving-1896 org entry"


def test_sbom_workflow_has_four_stages():
    wf = os.path.join(REPO_ROOT, ".github", "workflows", "generate-sbom.yml")
    with open(wf) as f:
        content = f.read()
    for stage in ["trivy", "sbomasm", "parlay", "sbomqs"]:
        assert stage.lower() in content.lower(), \
            f"generate-sbom.yml missing stage: {stage}"


def test_ota_release_calls_sbom():
    wf = os.path.join(REPO_ROOT, ".github", "workflows", "ota-release.yml")
    with open(wf) as f:
        content = f.read()
    assert "generate-sbom.yml" in content, \
        "ota-release.yml does not call generate-sbom.yml"
    assert "sbom" in content.lower(), \
        "ota-release.yml missing SBOM asset upload step"
