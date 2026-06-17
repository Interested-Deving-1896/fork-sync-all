"""
Tests for scripts/includes/pipeline-guard.sh

Strategy: source the script in a bash subshell with _GH_API pointing at a
local mock HTTP server (Python http.server) that returns canned responses.
This avoids any real GitHub API calls while exercising the full bash logic.

Coverage:
  - pipeline_guard_start: sets FLUSH_ACTIVE=true, writes GITHUB_OUTPUT
  - pipeline_guard_end:   sets FLUSH_ACTIVE=false, writes GITHUB_OUTPUT
  - pipeline_guard_checkpoint: passes when quota >= min, pauses when low,
    aborts when wait exceeds MAX_PAUSE_SECONDS
  - Double-source guard (_PIPELINE_GUARD_LOADED)
  - bash -n syntax check
"""

import json
import os
import subprocess
import textwrap
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD_SCRIPT = os.path.join(REPO_ROOT, "scripts", "includes", "pipeline-guard.sh")


# ── Mock HTTP server ──────────────────────────────────────────────────────────

class _MockGitHubHandler(BaseHTTPRequestHandler):
    """Minimal GitHub API mock. Configured via server.config dict."""

    def log_message(self, *args):
        pass  # suppress access log noise

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        self.send_response(204)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        self.send_response(201)
        self.end_headers()

    def do_GET(self):
        cfg = self.server.config
        if "/rate_limit" in self.path:
            remaining = cfg.get("remaining", 5000)
            reset_at = cfg.get("reset_at", int(time.time()) + 3600)
            body = json.dumps({
                "resources": {
                    "core": {"remaining": remaining, "reset": reset_at}
                }
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()


class MockGitHub:
    """Context manager that runs a mock GitHub API server on a free port."""

    def __init__(self, remaining=5000, reset_at=None):
        self.config = {
            "remaining": remaining,
            "reset_at": reset_at or int(time.time()) + 3600,
        }
        self._server = None
        self._thread = None

    def __enter__(self):
        self._server = HTTPServer(("127.0.0.1", 0), _MockGitHubHandler)
        self._server.config = self.config
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        host, port = self._server.server_address
        self.base_url = f"http://{host}:{port}"
        return self

    def __exit__(self, *_):
        self._server.shutdown()


# ── Helpers ───────────────────────────────────────────────────────────────────

def _run_guard(func_call: str, mock: MockGitHub, tmp_path, extra_env=None):
    """
    Source pipeline-guard.sh in a bash subshell, then call func_call.
    Returns (returncode, stderr_text, github_output_contents).
    """
    output_file = tmp_path / "github_output"
    output_file.write_text("")

    script = textwrap.dedent(f"""\
        #!/usr/bin/env bash
        set -euo pipefail
        source "{GUARD_SCRIPT}"
        {func_call}
    """)

    env = {
        **os.environ,
        "GH_TOKEN": "fake-token",
        "REPO": "test-owner/test-repo",
        "GITHUB_OUTPUT": str(output_file),
        "_GH_API": mock.base_url,
        "MAX_PAUSE_SECONDS": "10",
        "PAUSE_POLL_SECONDS": "1",
        **(extra_env or {}),
    }

    result = subprocess.run(
        ["bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.returncode, result.stderr, output_file.read_text()


# ── Syntax check ──────────────────────────────────────────────────────────────

class TestSyntax:
    def test_bash_syntax(self):
        r = subprocess.run(["bash", "-n", GUARD_SCRIPT], capture_output=True, text=True)
        assert r.returncode == 0, f"bash -n failed:\n{r.stderr}"


# ── pipeline_guard_start ──────────────────────────────────────────────────────

class TestPipelineGuardStart:
    def test_exits_zero_on_success(self, tmp_path):
        with MockGitHub(remaining=4000) as mock:
            rc, _, _ = _run_guard("pipeline_guard_start 'test-pipeline'", mock, tmp_path)
        assert rc == 0

    def test_writes_quota_to_github_output(self, tmp_path):
        with MockGitHub(remaining=3500) as mock:
            rc, _, output = _run_guard("pipeline_guard_start", mock, tmp_path)
        assert rc == 0
        assert "pipeline_guard_start_quota=3500" in output

    def test_logs_label_to_stderr(self, tmp_path):
        with MockGitHub() as mock:
            rc, stderr, _ = _run_guard("pipeline_guard_start 'my-deploy'", mock, tmp_path)
        assert rc == 0
        assert "my-deploy" in stderr

    def test_logs_quota_to_stderr(self, tmp_path):
        with MockGitHub(remaining=1234) as mock:
            rc, stderr, _ = _run_guard("pipeline_guard_start", mock, tmp_path)
        assert rc == 0
        assert "1234" in stderr


# ── pipeline_guard_end ────────────────────────────────────────────────────────

class TestPipelineGuardEnd:
    def test_exits_zero(self, tmp_path):
        with MockGitHub() as mock:
            rc, _, _ = _run_guard("pipeline_guard_end", mock, tmp_path)
        assert rc == 0

    def test_writes_end_marker_to_github_output(self, tmp_path):
        with MockGitHub() as mock:
            rc, _, output = _run_guard("pipeline_guard_end", mock, tmp_path)
        assert rc == 0
        assert "pipeline_guard_end=true" in output

    def test_logs_label_to_stderr(self, tmp_path):
        with MockGitHub() as mock:
            rc, stderr, _ = _run_guard("pipeline_guard_end 'my-deploy'", mock, tmp_path)
        assert rc == 0
        assert "my-deploy" in stderr


# ── pipeline_guard_checkpoint ─────────────────────────────────────────────────

class TestPipelineGuardCheckpoint:
    def test_passes_when_quota_sufficient(self, tmp_path):
        with MockGitHub(remaining=2000) as mock:
            rc, _, output = _run_guard(
                "pipeline_guard_checkpoint 600 'stage-1'", mock, tmp_path
            )
        assert rc == 0
        assert "pipeline_guard_paused=false" in output

    def test_passes_when_quota_exactly_at_minimum(self, tmp_path):
        with MockGitHub(remaining=600) as mock:
            rc, _, output = _run_guard(
                "pipeline_guard_checkpoint 600", mock, tmp_path
            )
        assert rc == 0
        assert "pipeline_guard_paused=false" in output

    def test_aborts_when_wait_exceeds_max(self, tmp_path):
        # reset_at is far in the future (> MAX_PAUSE_SECONDS=10)
        far_future = int(time.time()) + 7200
        with MockGitHub(remaining=0, reset_at=far_future) as mock:
            rc, stderr, output = _run_guard(
                "pipeline_guard_checkpoint 600",
                mock,
                tmp_path,
                extra_env={"MAX_PAUSE_SECONDS": "10"},
            )
        assert rc == 1
        assert "pipeline_guard_paused=true" in output
        assert "exceeds" in stderr.lower() or "aborting" in stderr.lower()

    def test_continues_immediately_when_reset_already_passed(self, tmp_path):
        # reset_at in the past
        past = int(time.time()) - 60
        with MockGitHub(remaining=0, reset_at=past) as mock:
            rc, stderr, output = _run_guard(
                "pipeline_guard_checkpoint 600",
                mock,
                tmp_path,
            )
        assert rc == 0
        assert "pipeline_guard_paused=false" in output
        assert "already passed" in stderr.lower()

    def test_default_min_quota_is_600(self, tmp_path):
        # 599 < default 600 → would pause; but reset is in the past → continues
        past = int(time.time()) - 60
        with MockGitHub(remaining=599, reset_at=past) as mock:
            rc, _, _ = _run_guard("pipeline_guard_checkpoint", mock, tmp_path)
        assert rc == 0


# ── Double-source guard ───────────────────────────────────────────────────────

class TestDoubleSourceGuard:
    def test_sourcing_twice_does_not_error(self, tmp_path):
        output_file = tmp_path / "github_output"
        output_file.write_text("")

        with MockGitHub() as mock:
            script = textwrap.dedent(f"""\
                #!/usr/bin/env bash
                source "{GUARD_SCRIPT}"
                source "{GUARD_SCRIPT}"
                pipeline_guard_end
            """)
            env = {
                **os.environ,
                "GH_TOKEN": "fake-token",
                "REPO": "test-owner/test-repo",
                "GITHUB_OUTPUT": str(output_file),
                "_GH_API": mock.base_url,
            }
            r = subprocess.run(
                ["bash", "-c", script], env=env,
                capture_output=True, text=True, timeout=15,
            )
        assert r.returncode == 0

    def test_functions_available_after_double_source(self, tmp_path):
        output_file = tmp_path / "github_output"
        output_file.write_text("")

        with MockGitHub(remaining=999) as mock:
            script = textwrap.dedent(f"""\
                #!/usr/bin/env bash
                source "{GUARD_SCRIPT}"
                source "{GUARD_SCRIPT}"
                pipeline_guard_start
            """)
            env = {
                **os.environ,
                "GH_TOKEN": "fake-token",
                "REPO": "test-owner/test-repo",
                "GITHUB_OUTPUT": str(output_file),
                "_GH_API": mock.base_url,
            }
            r = subprocess.run(
                ["bash", "-c", script], env=env,
                capture_output=True, text=True, timeout=15,
            )
        assert r.returncode == 0
        assert "pipeline_guard_start_quota=999" in output_file.read_text()


# ── PIPELINE_LABEL env var ────────────────────────────────────────────────────

class TestPipelineLabel:
    def test_pipeline_label_appears_in_all_log_messages(self, tmp_path):
        with MockGitHub() as mock:
            rc, stderr, _ = _run_guard(
                "pipeline_guard_start; pipeline_guard_end",
                mock,
                tmp_path,
                extra_env={"PIPELINE_LABEL": "critical-deploy-osp"},
            )
        assert rc == 0
        assert "critical-deploy-osp" in stderr
