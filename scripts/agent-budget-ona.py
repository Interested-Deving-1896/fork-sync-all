#!/usr/bin/env python3
"""Safe Ona provider adapter for agent-budget observation and goal control.

The billing endpoint used here reports *cumulative consumed credits*.  It does
not report the account's Core/credit balance, so this adapter deliberately
leaves ``remaining`` unknown.  A higher-level budget governor can combine this
provider snapshot with a separately configured allocation, but must not infer a
remaining balance from this response alone.

Goal pause/resume uses AgentService.SendToAgentExecution.  It never stops an
agent execution or its environment.  Mutating commands are dry-run unless the
operator supplies ``--apply``.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlsplit


DEFAULT_HOST = "https://app.gitpod.io"
TOKEN_ENVIRONMENT_VARIABLES = ("ONA_API_KEY", "GITPOD_API_KEY")

ENDPOINTS = {
    "usage": "/api/gitpod.v1.BillingService/GetCumulativeCreditUsage",
    "execution": "/api/gitpod.v1.AgentService/GetAgentExecution",
    "control": "/api/gitpod.v1.AgentService/SendToAgentExecution",
}

GOAL_STATUS_NAMES = {
    0: "GOAL_STATUS_UNSPECIFIED",
    1: "GOAL_STATUS_ACTIVE",
    2: "GOAL_STATUS_PAUSED",
    3: "GOAL_STATUS_COMPLETED",
    4: "GOAL_STATUS_BUDGET_EXHAUSTED",
    5: "GOAL_STATUS_BLOCKED",
    6: "GOAL_STATUS_USAGE_LIMITED",
}
PHASE_NAMES = {
    0: "PHASE_UNSPECIFIED",
    10: "PHASE_PENDING",
    20: "PHASE_RUNNING",
    30: "PHASE_WAITING_FOR_INPUT",
    40: "PHASE_STOPPED",
}
CONTROLLABLE_PHASES = {"PHASE_RUNNING", "PHASE_WAITING_FOR_INPUT"}
CONTROL_TRANSITIONS = {
    "pause": ("GOAL_STATUS_ACTIVE", "GOAL_STATUS_PAUSED"),
    "resume": ("GOAL_STATUS_PAUSED", "GOAL_STATUS_ACTIVE"),
}


class OnaAdapterError(RuntimeError):
    """A safe, operator-facing adapter error with no response bodies."""


class OnaStateError(OnaAdapterError):
    """The requested goal transition is not valid for the observed state."""


def canonical_uuid(value: str, label: str) -> str:
    """Validate and canonicalize an explicitly supplied Ona identifier."""
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise OnaAdapterError(f"{label} must be a UUID") from exc
    return str(parsed)


def validate_as_of(value: str) -> str:
    """Validate an RFC 3339 timestamp while preserving the supplied value."""
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise OnaAdapterError("--as-of must be an RFC 3339 timestamp") from exc
    return value


def validated_host(value: str) -> str:
    """Accept an HTTPS management-plane origin, without path or credentials."""
    candidate = value.rstrip("/")
    parts = urlsplit(candidate)
    if (
        parts.scheme != "https"
        or not parts.netloc
        or parts.path
        or parts.query
        or parts.fragment
        or parts.username
        or parts.password
    ):
        raise OnaAdapterError("ONA_HOST must be an HTTPS origin without a path or credentials")
    return candidate


def token_from_environment(environ: Mapping[str, str]) -> str:
    """Read the bearer token only from the documented environment variables."""
    for name in TOKEN_ENVIRONMENT_VARIABLES:
        token = environ.get(name, "").strip()
        if token:
            return token
    names = " or ".join(TOKEN_ENVIRONMENT_VARIABLES)
    raise OnaAdapterError(f"an Ona bearer token is required in {names}")


def _retry_delay(headers: Any, attempt: int) -> float:
    retry_after = headers.get("Retry-After") if headers is not None else None
    if retry_after:
        try:
            return min(60.0, max(0.0, float(retry_after)))
        except ValueError:
            pass
    return min(30.0, float(2**attempt))


@dataclass
class OnaClient:
    host: str
    token: str
    timeout: float = 20.0
    retries: int = 3
    opener: Callable[..., Any] = urllib.request.urlopen
    sleeper: Callable[[float], None] = time.sleep

    def post(self, endpoint: str, payload: Mapping[str, Any]) -> dict[str, Any]:
        """POST JSON to one of the three fixed, audited Ona API methods."""
        if endpoint not in ENDPOINTS.values():
            raise OnaAdapterError("unapproved Ona API endpoint")
        request = urllib.request.Request(
            f"{self.host}{endpoint}",
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "fork-sync-all-agent-budget-ona",
            },
        )
        for attempt in range(self.retries + 1):
            try:
                with self.opener(request, timeout=self.timeout) as response:
                    raw = response.read()
                if not raw:
                    return {}
                decoded = json.loads(raw.decode("utf-8"))
                if not isinstance(decoded, dict):
                    raise OnaAdapterError("Ona API returned a non-object response")
                return decoded
            except urllib.error.HTTPError as exc:
                retryable = exc.code == 429 or 500 <= exc.code <= 599
                if retryable and attempt < self.retries:
                    self.sleeper(_retry_delay(exc.headers, attempt))
                    continue
                # Never include the response body; it can contain internal data.
                raise OnaAdapterError(f"Ona API request failed with HTTP {exc.code}") from None
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                raise OnaAdapterError("Ona API request failed before receiving a response") from exc
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise OnaAdapterError("Ona API returned invalid JSON") from exc
        raise OnaAdapterError("Ona API retry limit reached")

    def cumulative_usage(self, organization_id: str, as_of: str | None = None) -> dict[str, Any]:
        payload: dict[str, Any] = {"organizationId": organization_id}
        if as_of:
            payload["asOf"] = as_of
        return self.post(ENDPOINTS["usage"], payload)

    def agent_execution(self, execution_id: str) -> dict[str, Any]:
        return self.post(ENDPOINTS["execution"], {"agentExecutionId": execution_id})

    def send_goal_control(self, execution_id: str, action: str) -> dict[str, Any]:
        if action not in CONTROL_TRANSITIONS:
            raise OnaAdapterError("unsupported goal control action")
        payload = goal_control_payload(execution_id, action)
        return self.post(ENDPOINTS["control"], payload)


def _number(value: Any, label: str, *, integer: bool = False) -> int | float | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        raise OnaAdapterError(f"Ona returned an invalid {label}")
    try:
        result: int | float = int(value) if integer else float(value)
    except (TypeError, ValueError) as exc:
        raise OnaAdapterError(f"Ona returned an invalid {label}") from exc
    if not math.isfinite(float(result)) or result < 0:
        raise OnaAdapterError(f"Ona returned an invalid {label}")
    return result


def _enum_name(value: Any, numeric_names: Mapping[int, str]) -> str | None:
    if value is None or value == "":
        return None
    if isinstance(value, int) and not isinstance(value, bool):
        return numeric_names.get(value, f"UNKNOWN_{value}")
    return str(value)


def normalize_usage(response: Mapping[str, Any], as_of: str | None = None) -> dict[str, Any]:
    """Normalize consumed Ona credits without manufacturing a balance."""
    org_usage = response.get("orgUsage") or {}
    if not isinstance(org_usage, Mapping):
        raise OnaAdapterError("Ona cumulative usage response has invalid orgUsage")
    total = _number(org_usage.get("totalCredits"), "totalCredits")
    if total is None:
        raise OnaAdapterError("Ona cumulative usage response omitted totalCredits")

    by_type: dict[str, int | float] = {}
    rows = org_usage.get("usageByType") or []
    if not isinstance(rows, list):
        raise OnaAdapterError("Ona cumulative usage response has invalid usageByType")
    for row in rows:
        if not isinstance(row, Mapping):
            continue
        usage_type = str(row.get("usageType") or "USAGE_TYPE_UNSPECIFIED")
        credits = _number(row.get("credits"), f"credits for {usage_type}")
        if credits is not None:
            by_type[usage_type] = credits

    return {
        "schema_version": 1,
        "provider": "ona",
        "scope": "organization",
        "metric": "credit_usage",
        "unit": "ona_credit",
        "semantics": "cumulative_consumed",
        "consumed": total,
        "consumed_by_type": dict(sorted(by_type.items())),
        "period_start": response.get("periodStart"),
        "as_of": as_of,
        "remaining": None,
        "remaining_known": False,
        "remaining_reason": "GetCumulativeCreditUsage does not return the Core credit balance",
        "team_count": len(response.get("teamUsage") or []),
        "user_count": len(response.get("userUsage") or []),
    }


def _execution_from_response(response: Mapping[str, Any]) -> Mapping[str, Any]:
    execution = response.get("agentExecution")
    if not isinstance(execution, Mapping):
        raise OnaAdapterError("Ona execution response omitted agentExecution")
    return execution


def execution_snapshot(response: Mapping[str, Any], requested_id: str) -> dict[str, Any]:
    """Return only lifecycle and metering fields; omit prompts, URLs, and messages."""
    execution = _execution_from_response(response)
    returned_id = execution.get("id")
    if returned_id and str(returned_id) != requested_id:
        raise OnaAdapterError("Ona returned a different agent execution")
    status = execution.get("status") or {}
    spec = execution.get("spec") or {}
    if not isinstance(status, Mapping) or not isinstance(spec, Mapping):
        raise OnaAdapterError("Ona execution response has invalid status or spec")
    goal = status.get("goal")
    if goal is not None and not isinstance(goal, Mapping):
        raise OnaAdapterError("Ona execution response has an invalid goal")
    goal = goal or {}

    token_fields = {
        "input": _number(status.get("inputTokensUsed"), "inputTokensUsed", integer=True),
        "output": _number(status.get("outputTokensUsed"), "outputTokensUsed", integer=True),
        "cached_creation": _number(
            status.get("cachedCreationTokensUsed"), "cachedCreationTokensUsed", integer=True
        ),
        "cached_input": _number(
            status.get("cachedInputTokensUsed"), "cachedInputTokensUsed", integer=True
        ),
        "context_window_length": _number(
            status.get("contextWindowLength"), "contextWindowLength", integer=True
        ),
        "context_window_limit": _number(
            status.get("contextWindowLimit"), "contextWindowLimit", integer=True
        ),
    }
    return {
        "schema_version": 1,
        "provider": "ona",
        "execution_id": requested_id,
        "phase": _enum_name(status.get("phase"), PHASE_NAMES),
        "desired_phase": _enum_name(spec.get("desiredPhase"), PHASE_NAMES),
        "model": status.get("supportedModel"),
        "mode": status.get("mode"),
        "iterations": _number(status.get("iterations"), "iterations", integer=True),
        "tokens": token_fields,
        "goal": {
            "present": bool(goal),
            "status": _enum_name(goal.get("status"), GOAL_STATUS_NAMES),
            "tokens_used": _number(goal.get("tokensUsed"), "goal tokensUsed", integer=True),
            "token_budget": _number(goal.get("tokenBudget"), "goal tokenBudget", integer=True),
            "time_used": goal.get("timeUsed"),
        },
    }


def get_execution_snapshot(client: OnaClient, execution_id: str) -> dict[str, Any]:
    return execution_snapshot(client.agent_execution(execution_id), execution_id)


def goal_control_payload(execution_id: str, action: str) -> dict[str, Any]:
    """Build the exact public AgentControlInput.Goal pause/resume oneof JSON."""
    if action not in CONTROL_TRANSITIONS:
        raise OnaAdapterError("unsupported goal control action")
    return {
        "agentExecutionId": execution_id,
        "controlInput": {"goal": {action: {}}},
    }


def _check_transition(snapshot: Mapping[str, Any], action: str) -> tuple[str, str, str]:
    current, target = CONTROL_TRANSITIONS[action]
    phase = snapshot.get("phase")
    goal = snapshot.get("goal") or {}
    goal_status = goal.get("status") if isinstance(goal, Mapping) else None
    if not goal.get("present"):
        raise OnaStateError("agent execution has no goal to control")
    if goal_status == target:
        return str(phase), str(goal_status), "already_target"
    if phase not in CONTROLLABLE_PHASES:
        raise OnaStateError(f"agent execution phase {phase or 'unknown'} is not controllable")
    if goal_status != current:
        raise OnaStateError(
            f"cannot {action} goal in state {goal_status or 'unknown'}; expected {current}"
        )
    return str(phase), str(goal_status), "ready"


def control_goal(
    client: OnaClient,
    execution_id: str,
    action: str,
    *,
    apply: bool = False,
    verify_attempts: int = 6,
    verify_interval: float = 1.0,
) -> dict[str, Any]:
    """Safely plan or apply an idempotent goal pause/resume transition."""
    before = get_execution_snapshot(client, execution_id)
    phase, before_status, readiness = _check_transition(before, action)
    target = CONTROL_TRANSITIONS[action][1]
    base = {
        "schema_version": 1,
        "provider": "ona",
        "execution_id": execution_id,
        "action": action,
        "phase": phase,
        "before_goal_status": before_status,
        "target_goal_status": target,
    }
    if readiness == "already_target":
        return {
            **base,
            "mode": "apply" if apply else "dry-run",
            "applied": False,
            "idempotent": True,
            "verified": True,
            "after_goal_status": before_status,
        }
    if not apply:
        return {
            **base,
            "mode": "dry-run",
            "applied": False,
            "idempotent": False,
            "verified": False,
            "would_send": goal_control_payload(execution_id, action),
        }

    client.send_goal_control(execution_id, action)
    attempts = max(1, verify_attempts)
    after = before
    for attempt in range(attempts):
        after = get_execution_snapshot(client, execution_id)
        after_goal = after.get("goal") or {}
        if after_goal.get("status") == target:
            return {
                **base,
                "mode": "apply",
                "applied": True,
                "idempotent": False,
                "verified": True,
                "after_goal_status": target,
                "after_phase": after.get("phase"),
            }
        if attempt + 1 < attempts:
            client.sleeper(max(0.0, verify_interval))
    final_goal = after.get("goal") or {}
    raise OnaStateError(
        f"goal control was sent but target state {target} was not observed "
        f"(last state {final_goal.get('status') or 'unknown'})"
    )


def _common_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument(
        "--host",
        default=os.environ.get("ONA_HOST") or DEFAULT_HOST,
        help="Ona management-plane HTTPS origin (default: ONA_HOST or app.gitpod.io)",
    )
    parser.add_argument("--timeout", type=float, default=20.0, help="HTTP timeout in seconds")
    parser.add_argument("--retries", type=int, default=3, help="retries for HTTP 429/5xx")
    return parser


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Observe Ona credit/token usage and safely pause or resume agent goals"
    )
    common = _common_parser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    observe = subparsers.add_parser("observe", parents=[common], help="observe cumulative credits")
    observe.add_argument("--organization-id", required=True)
    observe.add_argument("--as-of")

    execution = subparsers.add_parser(
        "execution", parents=[common], help="observe allowlisted agent executions"
    )
    execution.add_argument(
        "--execution-id",
        action="append",
        required=True,
        help="explicit agent execution UUID; repeat to observe more than one",
    )

    for action in ("pause", "resume"):
        control = subparsers.add_parser(
            action, parents=[common], help=f"{action} an agent goal (dry-run by default)"
        )
        control.add_argument("--execution-id", required=True)
        control.add_argument("--apply", action="store_true", help="send the goal control request")
        control.add_argument("--verify-attempts", type=int, default=6)
        control.add_argument("--verify-interval", type=float, default=1.0)
    return parser


def _validate_runtime_args(args: argparse.Namespace) -> None:
    if args.timeout <= 0:
        raise OnaAdapterError("--timeout must be positive")
    if args.retries < 0 or args.retries > 10:
        raise OnaAdapterError("--retries must be between 0 and 10")
    if hasattr(args, "verify_attempts") and args.verify_attempts < 1:
        raise OnaAdapterError("--verify-attempts must be positive")
    if hasattr(args, "verify_interval") and args.verify_interval < 0:
        raise OnaAdapterError("--verify-interval cannot be negative")


def run(args: argparse.Namespace, environ: Mapping[str, str]) -> dict[str, Any]:
    _validate_runtime_args(args)
    client = OnaClient(
        host=validated_host(args.host),
        token=token_from_environment(environ),
        timeout=args.timeout,
        retries=args.retries,
    )
    if args.command == "observe":
        organization_id = canonical_uuid(args.organization_id, "organization ID")
        as_of = validate_as_of(args.as_of) if args.as_of else None
        return normalize_usage(client.cumulative_usage(organization_id, as_of), as_of)
    if args.command == "execution":
        execution_ids = [canonical_uuid(value, "execution ID") for value in args.execution_id]
        if len(set(execution_ids)) != len(execution_ids):
            raise OnaAdapterError("duplicate --execution-id values are not allowed")
        return {
            "schema_version": 1,
            "provider": "ona",
            "executions": [get_execution_snapshot(client, value) for value in execution_ids],
        }
    if args.command in CONTROL_TRANSITIONS:
        execution_id = canonical_uuid(args.execution_id, "execution ID")
        return control_goal(
            client,
            execution_id,
            args.command,
            apply=args.apply,
            verify_attempts=args.verify_attempts,
            verify_interval=args.verify_interval,
        )
    raise OnaAdapterError("unsupported command")


def main(argv: Sequence[str] | None = None, environ: Mapping[str, str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        result = run(args, os.environ if environ is None else environ)
    except OnaAdapterError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 2
    print(json.dumps({"ok": True, **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
