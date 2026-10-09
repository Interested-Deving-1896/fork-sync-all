import importlib.util
import io
import json
import sys
import urllib.error
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/agent-budget-ona.py"
ORG_ID = "b0e12f6c-4c67-429d-a4a6-d9838b5da047"
EXECUTION_ID = "6fa1a3c7-fbb7-49d1-ba56-1890dc7c4c35"


def load_module():
    spec = importlib.util.spec_from_file_location("agent_budget_ona", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def execution_response(goal_status="GOAL_STATUS_ACTIVE", phase="PHASE_RUNNING"):
    return {
        "agentExecution": {
            "id": EXECUTION_ID,
            "metadata": {"name": "private name"},
            "spec": {"desiredPhase": "PHASE_RUNNING", "session": "private session"},
            "status": {
                "phase": phase,
                "failureMessage": "private failure",
                "conversationUrl": "https://private.example/conversation",
                "transcriptUrl": "https://private.example/transcript",
                "iterations": "7",
                "inputTokensUsed": "110",
                "outputTokensUsed": "22",
                "cachedCreationTokensUsed": "9",
                "cachedInputTokensUsed": "44",
                "contextWindowLength": "176",
                "contextWindowLimit": "200000",
                "supportedModel": "SUPPORTED_MODEL_SONNET_4_6",
                "mode": "AGENT_MODE_GOAL",
                "goal": {
                    "objective": "private objective",
                    "status": goal_status,
                    "tokensUsed": "176",
                    "tokenBudget": "5000",
                    "timeUsed": "123s",
                },
            },
        }
    }


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.controls = []
        self.sleeps = []

    def agent_execution(self, execution_id):
        assert execution_id == EXECUTION_ID
        return self.responses.pop(0)

    def send_goal_control(self, execution_id, action):
        self.controls.append((execution_id, action))
        return {}

    def sleeper(self, seconds):
        self.sleeps.append(seconds)


class FakeResponse:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.payload


def test_normalize_usage_is_explicitly_cumulative_not_a_remaining_balance():
    module = load_module()
    report = module.normalize_usage(
        {
            "orgUsage": {
                "totalCredits": 125.5,
                "usageByType": [
                    {"usageType": "USAGE_TYPE_ENVIRONMENT", "credits": 25},
                    {"usageType": "USAGE_TYPE_AGENTIC", "credits": 100.5},
                ],
            },
            "periodStart": "2026-10-01T00:00:00Z",
            "teamUsage": [{"displayName": "private team"}],
            "userUsage": [{"displayName": "private person"}],
        },
        "2026-10-09T00:00:00Z",
    )

    assert report["semantics"] == "cumulative_consumed"
    assert report["consumed"] == 125.5
    assert report["remaining"] is None
    assert report["remaining_known"] is False
    assert report["consumed_by_type"]["USAGE_TYPE_AGENTIC"] == 100.5
    assert "private" not in json.dumps(report)


def test_execution_snapshot_reports_metering_and_omits_prompts_urls_and_messages():
    module = load_module()
    report = module.execution_snapshot(execution_response(), EXECUTION_ID)
    serialized = json.dumps(report)

    assert report["phase"] == "PHASE_RUNNING"
    assert report["tokens"] == {
        "input": 110,
        "output": 22,
        "cached_creation": 9,
        "cached_input": 44,
        "context_window_length": 176,
        "context_window_limit": 200000,
    }
    assert report["goal"]["status"] == "GOAL_STATUS_ACTIVE"
    assert report["goal"]["token_budget"] == 5000
    assert "private objective" not in serialized
    assert "private.example" not in serialized
    assert "private failure" not in serialized


def test_pause_defaults_to_dry_run_and_builds_exact_goal_control_payload():
    module = load_module()
    client = FakeClient([execution_response()])
    report = module.control_goal(client, EXECUTION_ID, "pause")

    assert client.controls == []
    assert report["mode"] == "dry-run"
    assert report["would_send"] == {
        "agentExecutionId": EXECUTION_ID,
        "controlInput": {"goal": {"pause": {}}},
    }


def test_apply_pause_sends_goal_control_and_verifies_target_state():
    module = load_module()
    client = FakeClient(
        [execution_response(), execution_response(), execution_response("GOAL_STATUS_PAUSED")]
    )
    report = module.control_goal(
        client,
        EXECUTION_ID,
        "pause",
        apply=True,
        verify_attempts=3,
        verify_interval=0,
    )

    assert client.controls == [(EXECUTION_ID, "pause")]
    assert report["applied"] is True
    assert report["verified"] is True
    assert report["after_goal_status"] == "GOAL_STATUS_PAUSED"
    assert client.sleeps == [0.0]


def test_idempotent_resume_does_not_send_when_goal_is_already_active():
    module = load_module()
    client = FakeClient([execution_response("GOAL_STATUS_ACTIVE")])
    report = module.control_goal(client, EXECUTION_ID, "resume", apply=True)

    assert client.controls == []
    assert report["idempotent"] is True
    assert report["verified"] is True


def test_resume_rejects_stopped_execution_before_mutating():
    module = load_module()
    client = FakeClient([execution_response("GOAL_STATUS_PAUSED", "PHASE_STOPPED")])
    with pytest.raises(module.OnaStateError, match="not controllable"):
        module.control_goal(client, EXECUTION_ID, "resume", apply=True)
    assert client.controls == []


def test_client_retries_429_and_5xx_without_using_stop_endpoint():
    module = load_module()
    requests = []
    sleeps = []
    errors = [
        urllib.error.HTTPError("https://redacted", 429, "limited", {"Retry-After": "0"}, None),
        urllib.error.HTTPError("https://redacted", 503, "unavailable", {}, None),
    ]

    def opener(request, timeout):
        requests.append((request, timeout))
        if errors:
            raise errors.pop(0)
        return FakeResponse({"agentExecution": {"id": EXECUTION_ID}})

    client = module.OnaClient(
        "https://app.ona.com", "super-secret", retries=2, opener=opener, sleeper=sleeps.append
    )
    result = client.agent_execution(EXECUTION_ID)

    assert result["agentExecution"]["id"] == EXECUTION_ID
    assert sleeps == [0.0, 2.0]
    assert all("GetAgentExecution" in request.full_url for request, _ in requests)
    assert all("StopAgentExecution" not in request.full_url for request, _ in requests)
    assert requests[0][0].get_header("Authorization") == "Bearer super-secret"


def test_cli_has_no_token_argument_and_requires_token_from_environment(capsys):
    module = load_module()
    parser = module.build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["execution", "--execution-id", EXECUTION_ID, "--token", "secret"])
    capsys.readouterr()

    result = module.main(["execution", "--execution-id", EXECUTION_ID], environ={})
    captured = capsys.readouterr()
    assert result == 2
    assert "bearer token is required" in captured.err
    assert "secret" not in captured.err


def test_http_error_does_not_emit_response_body_or_token():
    module = load_module()
    secret = "top-secret-token"
    private_body = b'{"message":"private-person@example.com"}'

    def opener(_request, timeout):
        raise urllib.error.HTTPError(
            "https://app.ona.com", 403, "forbidden", {}, io.BytesIO(private_body)
        )

    client = module.OnaClient("https://app.ona.com", secret, retries=0, opener=opener)
    with pytest.raises(module.OnaAdapterError) as error:
        client.agent_execution(EXECUTION_ID)
    assert secret not in str(error.value)
    assert "private-person" not in str(error.value)


def test_execution_ids_are_explicit_uuid_allowlist_and_duplicates_fail():
    module = load_module()
    args = module.build_parser().parse_args(
        [
            "execution",
            "--execution-id",
            EXECUTION_ID,
            "--execution-id",
            EXECUTION_ID,
        ]
    )
    with pytest.raises(module.OnaAdapterError, match="duplicate"):
        module.run(args, {"ONA_API_KEY": "token"})

    with pytest.raises(module.OnaAdapterError, match="must be a UUID"):
        module.canonical_uuid("not-an-id", "execution ID")


def test_host_must_be_https_origin_without_credentials_or_path():
    module = load_module()
    assert module.validated_host("https://ona.example/") == "https://ona.example"
    for host in ("http://ona.example", "https://user:pass@ona.example", "https://ona.example/api"):
        with pytest.raises(module.OnaAdapterError):
            module.validated_host(host)


def test_empty_ona_host_environment_uses_the_default(monkeypatch):
    module = load_module()
    monkeypatch.setenv("ONA_HOST", "")
    args = module.build_parser().parse_args(
        ["execution", "--execution-id", EXECUTION_ID]
    )
    assert args.host == module.DEFAULT_HOST
