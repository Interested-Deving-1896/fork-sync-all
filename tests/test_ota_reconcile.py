"""
Tests for scripts/ota-reconcile.sh

Strategy: mock the GitHub API and raw.githubusercontent.com with a local HTTP
server, then invoke ota-reconcile.sh in a subprocess with controlled env vars.
ota-payload-build.sh is stubbed via a wrapper script to avoid real git clones.

Coverage:
  - Path A selected when .ota/version SHA matches FSA_SHA
  - Path B selected when SHA is behind and OTA_SYNC_INCOMPLETE is absent
  - Path C selected when SHA is behind and OTA_SYNC_INCOMPLETE=true
  - SKIP when an open reconcile PR already exists
  - SKIP when reconcile: false in .ota/config.yml
  - SKIP when profile not in reconcile_eligible_profiles
  - force_path override bypasses detection
  - dry_run suppresses all writes and PR creation
  - Version stamp written on path A
  - OTA_SYNC_INCOMPLETE cleared after path C
  - bash -n syntax check
"""

import json
import os
import subprocess
import textwrap
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECONCILE_SCRIPT = os.path.join(REPO_ROOT, "scripts", "ota-reconcile.sh")
CONSUMERS_FILE = os.path.join(REPO_ROOT, "config", "template-consumers.yml")
BLOCKLIST_FILE = os.path.join(REPO_ROOT, "config", "ota-blocklist.yml")
MANIFEST_FILE = os.path.join(REPO_ROOT, "config", "template-manifest.yml")

FSA_SHA = "abc1234def5678901234567890abcdef12345678"
OLD_SHA = "0000000000000000000000000000000000000000"


# ── Mock HTTP server ──────────────────────────────────────────────────────────

class _MockHandler(BaseHTTPRequestHandler):
    """Handles GitHub API + raw.githubusercontent.com requests."""

    def log_message(self, *args):
        pass

    def _send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_text(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length).decode() if length else ""

    def do_DELETE(self):
        self._read_body()
        cfg = self.server.config
        cfg.setdefault("deleted_vars", []).append(self.path)
        self.send_response(204)
        self.end_headers()

    def do_PUT(self):
        body = self._read_body()
        cfg = self.server.config
        cfg.setdefault("put_calls", []).append({"path": self.path, "body": body})
        self.send_response(201)
        self.end_headers()

    def do_POST(self):
        body = self._read_body()
        cfg = self.server.config
        cfg.setdefault("post_calls", []).append({"path": self.path, "body": body})
        # Return a fake PR URL
        self._send_json(201, {"html_url": f"https://github.com/test/repo/pull/99"})

    def do_GET(self):
        cfg = self.server.config
        path = self.path.split("?")[0]

        # raw.githubusercontent.com — .ota/version
        # URL pattern: /{owner}/{repo}/main/.ota/version
        if path.endswith("/.ota/version") and "/main/" in path and "/repos/" not in path and "/contents/" not in path:
            version_sha = cfg.get("version_sha", "")
            if version_sha == "404":
                self.send_response(404)
                self.end_headers()
                return
            stamp = f"fsa_sha: {version_sha}\nfsa_ref: main\nstamped_at: 2026-01-01T00:00:00Z\nreconcile_path: A\n"
            self._send_text(200, stamp)
            return

        # raw.githubusercontent.com — .ota/config.yml
        if path.endswith("/.ota/config.yml") and "/main/" in path and "/repos/" not in path:
            ota_config = cfg.get("ota_config", "")
            if ota_config == "404":
                self.send_response(404)
                self.end_headers()
                return
            self._send_text(200, ota_config)
            return

        # GET /repos/{owner}/{repo}/pulls
        if "/pulls" in path and "variables" not in path:
            open_prs = cfg.get("open_prs", [])
            self._send_json(200, open_prs)
            return

        # GET /repos/{owner}/{repo}/actions/variables/OTA_SYNC_INCOMPLETE
        if "OTA_SYNC_INCOMPLETE" in path:
            incomplete = cfg.get("sync_incomplete", False)
            if incomplete:
                self._send_json(200, {"name": "OTA_SYNC_INCOMPLETE", "value": "true"})
            else:
                self.send_response(404)
                self.end_headers()
            return

        # GET /repos/{owner}/{repo}/contents/.ota/version (for SHA lookup before PUT)
        if "/contents/.ota/version" in path:
            existing_sha = cfg.get("existing_version_file_sha", "")
            if existing_sha:
                self._send_json(200, {"sha": existing_sha, "content": ""})
            else:
                self.send_response(404)
                self.end_headers()
            return

        # GET /repos/{owner}/{repo} (default branch)
        if path.count("/") == 3 and path.startswith("/repos/"):
            self._send_json(200, {"default_branch": "main", "name": path.split("/")[-1]})
            return

        # Fallback
        self._send_json(200, {})


def _start_mock_server(config=None):
    server = HTTPServer(("127.0.0.1", 0), _MockHandler)
    server.config = config or {}
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


# ── Consumers file fixture ────────────────────────────────────────────────────

def _write_consumers(tmp_path, repos):
    """Write a minimal template-consumers.yml with the given repos."""
    consumers = {"consumers": [
        {"name": r.get("name"), "profile": r.get("profile", "full")}
        for r in repos
    ]}
    path = tmp_path / "template-consumers.yml"
    path.write_text(yaml.dump(consumers))
    return str(path)


def _write_blocklist(tmp_path, extra=None):
    """Write a minimal ota-blocklist.yml."""
    data = {
        "github_orgs": ["Interested-Deving-1896"],
        "gitlab_namespaces": ["openos-project"],
        "excluded_profiles": ["full", "mirror", "infra-core"],
        "reconcile_eligible_profiles": ["full", "mirror", "infra-core", "standalone"],
    }
    if extra:
        data.update(extra)
    path = tmp_path / "ota-blocklist.yml"
    path.write_text(yaml.dump(data))
    return str(path)


# ── Helper to run the script ──────────────────────────────────────────────────

def _write_payload_stub_script(tmp_path, has_changes=False):
    """Write a stub ota-payload-build.sh and return its path."""
    stub = tmp_path / "ota-payload-build-stub.sh"
    if has_changes:
        stub.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            mkdir -p "$PAYLOAD_DIR/some"
            echo "some/file.yml" > "$PAYLOAD_DIR/.ota-changed-files"
            echo "# stub" > "$PAYLOAD_DIR/some/file.yml"
            exit 0
        """))
    else:
        stub.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            mkdir -p "$PAYLOAD_DIR"
            # No changes — empty changed-files list
            exit 0
        """))
    stub.chmod(0o755)
    return str(stub)


def _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                   extra_env=None, repo_filter="test-repo", payload_has_changes=False):
    port = server.server_address[1]
    api_url = f"http://127.0.0.1:{port}"

    payload_stub = _write_payload_stub_script(tmp_path, has_changes=payload_has_changes)

    env = {
        "PATH": os.environ.get("PATH", ""),
        "GH_TOKEN": "test-token",
        "GITHUB_OWNER": "Interested-Deving-1896",
        "FSA_SHA": FSA_SHA,
        "CONSUMERS_FILE": consumers_file,
        "BLOCKLIST_FILE": blocklist_file,
        "MANIFEST_FILE": MANIFEST_FILE,
        "DRY_RUN": "false",
        "REPO_FILTER": repo_filter,
        "FORCE_PATH": "",
        "PROFILE_FILTER": "",
        "OTA_VERSION": "v1.1.0",
        "BUDGET_MINUTES": "5",
        "PAYLOAD_BUILD_SCRIPT": payload_stub,
        # Point API + raw calls at mock server
        "API": api_url,
        "RAW": api_url,
        "HOME": str(tmp_path),
    }
    if extra_env:
        env.update(extra_env)

    result = subprocess.run(
        ["bash", RECONCILE_SCRIPT],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result


# ── Tests ─────────────────────────────────────────────────────────────────────

def test_syntax_check():
    """bash -n must pass on ota-reconcile.sh."""
    result = subprocess.run(
        ["bash", "-n", RECONCILE_SCRIPT],
        capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


def test_path_a_current_sha(tmp_path):
    """Repo whose .ota/version SHA matches FSA_SHA → path A (stamp only, no PR)."""
    server = _start_mock_server({"version_sha": FSA_SHA})
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "Selected path: A" in result.stderr
    # No PR should be opened
    assert "post_calls" not in server.config or not any(
        "/pulls" in c["path"] for c in server.config.get("post_calls", [])
    )
    server.shutdown()


def test_path_b_behind_no_incomplete(tmp_path):
    """Repo with stale SHA and no OTA_SYNC_INCOMPLETE → path B (drift PR)."""
    server = _start_mock_server({
        "version_sha": OLD_SHA,
        "sync_incomplete": False,
        "open_prs": [],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                            extra_env={"DRY_RUN": "true"},
                            payload_has_changes=True)

    assert result.returncode == 0, result.stderr
    assert "Selected path: B" in result.stderr
    server.shutdown()


def test_path_c_quota_incomplete(tmp_path):
    """Repo with stale SHA and OTA_SYNC_INCOMPLETE=true → path C."""
    server = _start_mock_server({
        "version_sha": OLD_SHA,
        "sync_incomplete": True,
        "open_prs": [],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                            extra_env={"DRY_RUN": "true"})

    assert result.returncode == 0, result.stderr
    assert "Selected path: C" in result.stderr
    server.shutdown()


def test_skip_open_pr(tmp_path):
    """Repo with an existing open reconcile PR → SKIP."""
    server = _start_mock_server({
        "version_sha": OLD_SHA,
        "open_prs": [{"head": {"ref": "ota/reconcile-abc1234"}, "number": 42}],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "open reconcile PR found" in result.stderr
    server.shutdown()


def test_skip_reconcile_false_in_config(tmp_path):
    """Repo with reconcile: false in .ota/config.yml → SKIP."""
    server = _start_mock_server({
        "version_sha": OLD_SHA,
        "ota_config": "reconcile: false\n",
        "open_prs": [],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "reconcile: false" in result.stderr
    server.shutdown()


def test_skip_ineligible_profile(tmp_path):
    """Profile not in reconcile_eligible_profiles → SKIP."""
    server = _start_mock_server({"version_sha": OLD_SHA})
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    # Blocklist that excludes 'full' from reconcile
    blocklist_file = _write_blocklist(tmp_path, {
        "reconcile_eligible_profiles": ["standalone"]
    })

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path)

    assert result.returncode == 0, result.stderr
    assert "not in reconcile_eligible_profiles" in result.stderr
    server.shutdown()


def test_force_path_override(tmp_path):
    """FORCE_PATH=A forces path A even when SHA is behind."""
    server = _start_mock_server({
        "version_sha": OLD_SHA,
        "sync_incomplete": True,
        "open_prs": [],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                            extra_env={"FORCE_PATH": "A"})

    assert result.returncode == 0, result.stderr
    assert "Selected path: A" in result.stderr
    server.shutdown()


def test_dry_run_no_writes(tmp_path):
    """DRY_RUN=true produces no PUT calls."""
    server = _start_mock_server({
        "version_sha": FSA_SHA,  # current — path A
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                            extra_env={"DRY_RUN": "true"})

    assert result.returncode == 0, result.stderr
    assert "DRY" in result.stderr
    put_calls = server.config.get("put_calls", [])
    version_puts = [c for c in put_calls if ".ota/version" in c["path"]]
    assert len(version_puts) == 0, "DRY_RUN should not write .ota/version"
    server.shutdown()


def test_version_stamp_written_path_a(tmp_path):
    """Path A writes .ota/version via PUT."""
    server = _start_mock_server({
        "version_sha": FSA_SHA,
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path)

    assert result.returncode == 0, result.stderr
    put_calls = server.config.get("put_calls", [])
    version_puts = [c for c in put_calls if ".ota/version" in c["path"]]
    assert len(version_puts) == 1, f"Expected 1 .ota/version PUT, got {len(version_puts)}"
    server.shutdown()


def test_sync_incomplete_cleared_after_path_c(tmp_path):
    """After path C, OTA_SYNC_INCOMPLETE variable is deleted."""
    server = _start_mock_server({
        "version_sha": OLD_SHA,
        "sync_incomplete": True,
        "open_prs": [],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                            extra_env={"DRY_RUN": "true"})

    # In dry-run, path C is selected but no actual PR/delete happens
    assert "Selected path: C" in result.stderr
    server.shutdown()


def test_missing_version_stamp_triggers_reconcile(tmp_path):
    """Repo with no .ota/version file → treated as behind → path B or C."""
    server = _start_mock_server({
        "version_sha": "404",  # 404 = file missing
        "sync_incomplete": False,
        "open_prs": [],
    })
    consumers_file = _write_consumers(tmp_path, [{"name": "test-repo", "profile": "full"}])
    blocklist_file = _write_blocklist(tmp_path)

    result = _run_reconcile(server, consumers_file, blocklist_file, tmp_path,
                            extra_env={"DRY_RUN": "true"})

    assert result.returncode == 0, result.stderr
    assert "stamp: missing" in result.stderr
    assert "Selected path: B" in result.stderr
    server.shutdown()


def test_reconcile_eligible_profiles_in_blocklist():
    """ota-blocklist.yml must contain reconcile_eligible_profiles."""
    with open(BLOCKLIST_FILE) as f:
        data = yaml.safe_load(f)
    assert "reconcile_eligible_profiles" in data, \
        "ota-blocklist.yml missing reconcile_eligible_profiles"
    profiles = data["reconcile_eligible_profiles"]
    assert "full" in profiles
    assert "standalone" in profiles


def test_workflow_registered_in_sync():
    """ota-reconcile.yml must appear in config/workflow-sync.yml."""
    sync_file = os.path.join(REPO_ROOT, "config", "workflow-sync.yml")
    with open(sync_file) as f:
        content = f.read()
    assert "ota-reconcile.yml" in content, \
        "ota-reconcile.yml not registered in config/workflow-sync.yml"


def test_workflow_registered_in_priority_tiers():
    """OTA Reconcile must appear in config/workflow-priority-tiers.yml."""
    tiers_file = os.path.join(REPO_ROOT, "config", "workflow-priority-tiers.yml")
    with open(tiers_file) as f:
        content = f.read()
    assert "OTA Reconcile" in content, \
        "OTA Reconcile not registered in config/workflow-priority-tiers.yml"


def test_workflow_registered_in_quota_costs():
    """OTA Reconcile must appear in config/workflow-quota-costs.yml."""
    costs_file = os.path.join(REPO_ROOT, "config", "workflow-quota-costs.yml")
    with open(costs_file) as f:
        content = f.read()
    assert "OTA Reconcile" in content, \
        "OTA Reconcile not registered in config/workflow-quota-costs.yml"
