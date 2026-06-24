"""
Tests for the PR/MR lifecycle guard system.

Coverage:
  scripts/includes/pr-lifecycle.sh:
    - pr_lifecycle_check passes when quota >= PR_MIN_QUOTA
    - pr_lifecycle_check defers and returns 1 when quota < PR_MIN_QUOTA
    - Deferred items written to Actions variable (POST then PATCH on 409)
    - Dispatch called with correct workflow file on defer
    - pr_lifecycle_done removes item from deferred set
    - pr_lifecycle_report clears var when all items complete
    - pr_lifecycle_deferred predicate reflects state correctly
    - DRY_RUN suppresses all API writes

  Script syntax:
    - scripts/includes/pr-lifecycle.sh
    - scripts/ota-deliver.sh
    - scripts/upstream-prs.sh
    - scripts/rebase-prs.sh

  Workflow YAML validity:
    - .github/workflows/pr-lifecycle-guard.yml
    - .github/workflows/pr-gate.yml

  Config registration:
    - pr-lifecycle-guard.yml and pr-gate.yml in workflow-sync.yml
    - PR Gate (tier 1) and PR Lifecycle Guard (tier 2) in workflow-priority-tiers.yml
    - PR Gate and PR Lifecycle Guard in workflow-quota-costs.yml

  Workflow wiring:
    - ota-release.yml references pr-lifecycle-guard.yml
    - upstream-prs.yml references pr-lifecycle-guard.yml
    - rebase-prs.yml inlines quota pre-flight (cannot call reusable workflow
      from workflow_run trigger — GitHub prohibits the combination)
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
INCLUDE = os.path.join(REPO_ROOT, "scripts", "includes", "pr-lifecycle.sh")


# ── Mock HTTP server ──────────────────────────────────────────────────────────

class _MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n).decode() if n else ""

    def do_GET(self):
        cfg = self.server.config
        cfg.setdefault("get_calls", []).append(self.path)
        quota = cfg.get("quota_remaining", 5000)
        body = json.dumps({"resources": {"core": {"remaining": quota, "reset": 9999999999}}}).encode()
        self._send(200, body)

    def do_POST(self):
        body = self._read_body()
        cfg = self.server.config
        cfg.setdefault("post_calls", []).append({"path": self.path, "body": body})
        # Simulate 409 on second variable POST to test PATCH fallback
        if "/actions/variables" in self.path and cfg.get("var_exists"):
            self._send(409, b"{}")
        else:
            self._send(201, b'{"id":1}')

    def do_PATCH(self):
        body = self._read_body()
        cfg = self.server.config
        cfg.setdefault("patch_calls", []).append({"path": self.path, "body": body})
        self._send(200, b'{"id":1}')

    def do_DELETE(self):
        cfg = self.server.config
        cfg.setdefault("delete_calls", []).append(self.path)
        self._send(204)


def _start_mock(config=None):
    s = HTTPServer(("127.0.0.1", 0), _MockHandler)
    s.config = config or {}
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


# ── Helper to run a bash snippet that sources pr-lifecycle.sh ─────────────────

def _run_lifecycle(server, script_body, extra_env=None):
    """Run a bash snippet with pr-lifecycle.sh sourced and API pointed at mock."""
    port = server.server_address[1]
    api = f"http://127.0.0.1:{port}"

    env = dict(os.environ)
    env.update({
        "GH_TOKEN": "tok",
        "REPO": "test-org/test-repo",
        "API": api,
        "PR_LIFECYCLE_DRY": "false",
        "GITHUB_OUTPUT": "/dev/null",
        "GITHUB_REPOSITORY": "test-org/test-repo",
    })
    if extra_env:
        env.update(extra_env)

    full_script = f"""
set -uo pipefail
source {INCLUDE}
{script_body}
"""
    result = subprocess.run(
        ["bash", "-c", full_script],
        env=env, capture_output=True, text=True, timeout=15
    )
    return result


# ── pr_lifecycle_check: quota OK ──────────────────────────────────────────────

def test_check_passes_when_quota_sufficient():
    server = _start_mock({"quota_remaining": 5000})
    result = _run_lifecycle(server, """
pr_lifecycle_init "test.yml" "test-key"
pr_lifecycle_defer "repo-a"
pr_lifecycle_check "repo-a"
echo "exit:$?"
""")
    assert result.returncode == 0, result.stderr
    assert "exit:0" in result.stdout
    server.shutdown()


def test_check_fails_when_quota_exhausted():
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "test.yml" "test-key"
pr_lifecycle_defer "repo-a"
pr_lifecycle_check "repo-a"
echo "exit:$?"
""", extra_env={"PR_MIN_QUOTA": "300"})
    # Script returns 1 from pr_lifecycle_check; bash -c exits 1 unless we capture
    assert "exit:1" in result.stdout
    server.shutdown()


# ── Defer writes correct items to Actions variable ────────────────────────────

def test_defer_writes_remaining_items_to_var():
    """Items registered but not done should be written to the Actions variable."""
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "deliver.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_defer "org/repo-b"
pr_lifecycle_defer "org/repo-c"
pr_lifecycle_done "org/repo-a"
pr_lifecycle_check "org/repo-b" || true
""", extra_env={"PR_MIN_QUOTA": "300"})
    # Should have POSTed to /actions/variables with repo-b and repo-c
    post_calls = server.config.get("post_calls", [])
    var_posts = [c for c in post_calls if "/actions/variables" in c["path"]]
    assert len(var_posts) >= 1, f"Expected variable POST, got: {post_calls}"
    body = json.loads(var_posts[0]["body"])
    assert body["name"] == "PR_LIFECYCLE_DEFER_OTA_DELIVER"
    deferred_items = body["value"].strip().splitlines()
    assert "org/repo-b" in deferred_items
    assert "org/repo-c" in deferred_items
    # repo-a was done — should NOT be in deferred
    assert "org/repo-a" not in deferred_items
    server.shutdown()


def test_defer_patches_on_409():
    """When the variable already exists (409), should PATCH instead of POST."""
    server = _start_mock({"quota_remaining": 50, "var_exists": True})
    result = _run_lifecycle(server, """
pr_lifecycle_init "deliver.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_check "org/repo-a" || true
""", extra_env={"PR_MIN_QUOTA": "300"})
    patch_calls = server.config.get("patch_calls", [])
    var_patches = [c for c in patch_calls if "/actions/variables" in c["path"]]
    assert len(var_patches) >= 1, "Expected PATCH on 409"
    server.shutdown()


# ── Dispatch called on defer ──────────────────────────────────────────────────

def test_dispatch_called_with_correct_workflow():
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "ota-release.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_check "org/repo-a" || true
""", extra_env={"PR_MIN_QUOTA": "300"})
    post_calls = server.config.get("post_calls", [])
    dispatch_calls = [c for c in post_calls if "/dispatches" in c["path"]]
    assert len(dispatch_calls) == 1, f"Expected 1 dispatch call, got: {dispatch_calls}"
    assert "ota-release.yml" in dispatch_calls[0]["path"]
    server.shutdown()


def test_dispatch_not_called_when_no_deferred_items():
    """If all items are done before quota runs out, no dispatch should fire."""
    server = _start_mock({"quota_remaining": 5000})
    result = _run_lifecycle(server, """
pr_lifecycle_init "ota-release.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_check "org/repo-a"
pr_lifecycle_done "org/repo-a"
pr_lifecycle_report
""")
    post_calls = server.config.get("post_calls", [])
    dispatch_calls = [c for c in post_calls if "/dispatches" in c["path"]]
    assert len(dispatch_calls) == 0, "Should not dispatch when all items complete"
    server.shutdown()


# ── pr_lifecycle_report clears var on full completion ─────────────────────────

def test_report_deletes_var_on_full_completion():
    server = _start_mock({"quota_remaining": 5000})
    result = _run_lifecycle(server, """
pr_lifecycle_init "ota-release.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_check "org/repo-a"
pr_lifecycle_done "org/repo-a"
pr_lifecycle_report
""")
    delete_calls = server.config.get("delete_calls", [])
    assert any("PR_LIFECYCLE_DEFER_OTA_DELIVER" in c for c in delete_calls), \
        f"Expected DELETE of defer var, got: {delete_calls}"
    server.shutdown()


def test_report_does_not_delete_var_when_deferred():
    """If a defer was triggered, the var must persist for the next run."""
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "ota-release.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_check "org/repo-a" || true
pr_lifecycle_report
""", extra_env={"PR_MIN_QUOTA": "300"})
    delete_calls = server.config.get("delete_calls", [])
    var_deletes = [c for c in delete_calls if "PR_LIFECYCLE_DEFER" in c]
    assert len(var_deletes) == 0, "Should not delete var when items are still deferred"
    server.shutdown()


# ── pr_lifecycle_deferred predicate ──────────────────────────────────────────

def test_deferred_predicate_true_after_quota_exhaustion():
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "test.yml" "test"
pr_lifecycle_defer "repo-a"
pr_lifecycle_check "repo-a" || true
if pr_lifecycle_deferred; then echo "DEFERRED=true"; else echo "DEFERRED=false"; fi
""", extra_env={"PR_MIN_QUOTA": "300"})
    assert "DEFERRED=true" in result.stdout, result.stderr
    server.shutdown()


def test_deferred_predicate_false_when_all_complete():
    server = _start_mock({"quota_remaining": 5000})
    result = _run_lifecycle(server, """
pr_lifecycle_init "test.yml" "test"
pr_lifecycle_defer "repo-a"
pr_lifecycle_check "repo-a"
pr_lifecycle_done "repo-a"
if pr_lifecycle_deferred; then echo "DEFERRED=true"; else echo "DEFERRED=false"; fi
""")
    assert "DEFERRED=false" in result.stdout, result.stderr
    server.shutdown()


# ── DRY_RUN suppresses API writes ────────────────────────────────────────────

def test_dry_run_suppresses_var_write_and_dispatch():
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "ota-release.yml" "ota-deliver"
pr_lifecycle_defer "org/repo-a"
pr_lifecycle_check "org/repo-a" || true
pr_lifecycle_report
""", extra_env={"PR_MIN_QUOTA": "300", "PR_LIFECYCLE_DRY": "true"})
    post_calls = server.config.get("post_calls", [])
    patch_calls = server.config.get("patch_calls", [])
    delete_calls = server.config.get("delete_calls", [])
    assert len(post_calls) == 0, f"DRY_RUN should suppress POSTs: {post_calls}"
    assert len(patch_calls) == 0, f"DRY_RUN should suppress PATCHes: {patch_calls}"
    assert len(delete_calls) == 0, f"DRY_RUN should suppress DELETEs: {delete_calls}"
    server.shutdown()


# ── Key sanitisation ──────────────────────────────────────────────────────────

def test_key_sanitised_to_uppercase_underscores():
    """Keys with hyphens and mixed case should produce valid var names."""
    server = _start_mock({"quota_remaining": 50})
    result = _run_lifecycle(server, """
pr_lifecycle_init "test.yml" "upstream-prs"
pr_lifecycle_defer "repo-a"
pr_lifecycle_check "repo-a" || true
""", extra_env={"PR_MIN_QUOTA": "300"})
    post_calls = server.config.get("post_calls", [])
    var_posts = [c for c in post_calls if "/actions/variables" in c["path"]]
    if var_posts:
        body = json.loads(var_posts[0]["body"])
        assert body["name"] == "PR_LIFECYCLE_DEFER_UPSTREAM_PRS"
    server.shutdown()


# ── Script syntax checks ──────────────────────────────────────────────────────

@pytest.mark.parametrize("script", [
    "scripts/includes/pr-lifecycle.sh",
    "scripts/ota-deliver.sh",
    "scripts/upstream-prs.sh",
    "scripts/rebase-prs.sh",
])
def test_script_syntax(script):
    path = os.path.join(REPO_ROOT, script)
    r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
    assert r.returncode == 0, f"{script} syntax error:\n{r.stderr}"


# ── Workflow YAML validity ────────────────────────────────────────────────────

def _load_workflow(path):
    """Load a workflow YAML, normalising the bare 'on' key (parsed as True by PyYAML)."""
    with open(path) as f:
        doc = yaml.safe_load(f)
    # PyYAML parses bare `on:` as boolean True — normalise to string "on"
    if True in doc and "on" not in doc:
        doc["on"] = doc.pop(True)
    return doc


@pytest.mark.parametrize("workflow", [
    ".github/workflows/pr-lifecycle-guard.yml",
    ".github/workflows/pr-gate.yml",
])
def test_workflow_yaml_valid(workflow):
    path = os.path.join(REPO_ROOT, workflow)
    doc = _load_workflow(path)
    assert isinstance(doc, dict), f"{workflow} did not parse as a YAML mapping"
    assert "name" in doc, f"{workflow} missing 'name' field"
    assert "on" in doc, f"{workflow} missing 'on' trigger"
    assert "jobs" in doc, f"{workflow} missing 'jobs'"


def test_pr_lifecycle_guard_has_workflow_call():
    path = os.path.join(REPO_ROOT, ".github/workflows/pr-lifecycle-guard.yml")
    doc = _load_workflow(path)
    triggers = doc.get("on", {})
    assert "workflow_call" in triggers, "pr-lifecycle-guard.yml must have workflow_call trigger"


def test_pr_lifecycle_guard_outputs_proceed():
    path = os.path.join(REPO_ROOT, ".github/workflows/pr-lifecycle-guard.yml")
    doc = _load_workflow(path)
    outputs = doc.get("on", {}).get("workflow_call", {}).get("outputs", {})
    assert "proceed" in outputs, "pr-lifecycle-guard.yml must expose 'proceed' output"


def test_pr_gate_triggers_on_pull_request():
    path = os.path.join(REPO_ROOT, ".github/workflows/pr-gate.yml")
    doc = _load_workflow(path)
    triggers = doc.get("on", {})
    assert "pull_request" in triggers, "pr-gate.yml must trigger on pull_request"


# ── Config registration ───────────────────────────────────────────────────────

def test_new_workflows_in_workflow_sync():
    with open(os.path.join(REPO_ROOT, "config", "workflow-sync.yml")) as f:
        content = f.read()
    for wf in ["pr-lifecycle-guard.yml", "pr-gate.yml"]:
        assert wf in content, f"{wf} missing from workflow-sync.yml"


def test_pr_gate_is_tier_1():
    with open(os.path.join(REPO_ROOT, "config", "workflow-priority-tiers.yml")) as f:
        doc = yaml.safe_load(f)
    tiers = {entry["name"]: entry["tier"] for entry in doc.get("tiers", [])}
    assert tiers.get("PR Gate") == 1, f"PR Gate should be tier 1, got: {tiers.get('PR Gate')}"


def test_pr_lifecycle_guard_is_tier_2():
    with open(os.path.join(REPO_ROOT, "config", "workflow-priority-tiers.yml")) as f:
        doc = yaml.safe_load(f)
    tiers = {entry["name"]: entry["tier"] for entry in doc.get("tiers", [])}
    assert tiers.get("PR Lifecycle Guard") == 2, \
        f"PR Lifecycle Guard should be tier 2, got: {tiers.get('PR Lifecycle Guard')}"


def test_new_workflows_in_quota_costs():
    with open(os.path.join(REPO_ROOT, "config", "workflow-quota-costs.yml")) as f:
        content = f.read()
    for name in ["PR Gate", "PR Lifecycle Guard"]:
        assert name in content, f"{name} missing from workflow-quota-costs.yml"


# ── Workflow wiring ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("workflow,caller", [
    (".github/workflows/ota-release.yml", "OTA Release"),
    (".github/workflows/upstream-prs.yml", "Upstream PRs from OSP + OOC"),
    # rebase-prs.yml is excluded: it uses workflow_run which prohibits calling
    # a reusable workflow. Quota pre-flight is inlined as steps instead.
])
def test_workflow_calls_pr_lifecycle_guard(workflow, caller):
    path = os.path.join(REPO_ROOT, workflow)
    with open(path) as f:
        content = f.read()
    assert "pr-lifecycle-guard.yml" in content, \
        f"{workflow} ({caller}) should call pr-lifecycle-guard.yml"


@pytest.mark.parametrize("workflow", [
    ".github/workflows/ota-release.yml",
    ".github/workflows/upstream-prs.yml",
    # rebase-prs.yml excluded — see test_workflow_calls_pr_lifecycle_guard
])
def test_workflow_gates_on_proceed_output(workflow):
    path = os.path.join(REPO_ROOT, workflow)
    with open(path) as f:
        content = f.read()
    assert "guard.outputs.proceed" in content, \
        f"{workflow} should gate on needs.guard.outputs.proceed"
