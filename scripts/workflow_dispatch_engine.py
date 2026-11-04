#!/usr/bin/env python3
"""Policy-gated GitHub Actions workflow dispatch engine.

Dry-run is the default. A live dispatch requires both an explicit CLI flag and
an exact policy-defined confirmation value. Tokens and input values are never
included in result objects or logs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping


class DispatchError(ValueError):
    """A request was rejected or the provider operation failed."""


@dataclass(frozen=True)
class WorkflowPolicy:
    repository: str
    workflow: str
    allowed_refs: tuple[str, ...]
    enabled: bool
    confirmation_input: str | None
    confirmation_value: str | None
    required_inputs: tuple[str, ...]
    input_allowlists: Mapping[str, tuple[str, ...]]
    protected: bool = False


def load_policy(path: str | Path, repository: str, workflow: str) -> WorkflowPolicy:
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DispatchError("Unable to read workflow dispatch policy") from exc
    if raw.get("version") != 1 or not isinstance(raw.get("workflows"), list):
        raise DispatchError("Unsupported or malformed workflow dispatch policy")
    for item in raw["workflows"]:
        if item.get("repository") != repository or item.get("workflow") != workflow:
            continue
        if not isinstance(item.get("allowed_refs"), list) or not item["allowed_refs"]:
            raise DispatchError("Policy must define at least one allowed ref")
        allowlists = item.get("input_allowlists", {})
        if not isinstance(allowlists, dict):
            raise DispatchError("Policy input_allowlists must be an object")
        return WorkflowPolicy(
            repository=repository,
            workflow=workflow,
            allowed_refs=tuple(item["allowed_refs"]),
            enabled=item.get("enabled") is True,
            confirmation_input=item.get("confirmation_input"),
            confirmation_value=item.get("confirmation_value"),
            required_inputs=tuple(item.get("required_inputs", [])),
            input_allowlists={k: tuple(v) for k, v in allowlists.items()},
            protected=item.get("protected") is True,
        )
    raise DispatchError("Workflow is not registered in the dispatch policy")


def validate_request(policy: WorkflowPolicy, ref: str, inputs: Mapping[str, str],
                     authorize: bool, confirmation: str | None) -> None:
    if not policy.enabled:
        raise DispatchError("Workflow dispatch is disabled by policy")
    if ref not in policy.allowed_refs:
        raise DispatchError("Requested ref is not allowed by policy")
    if not re.fullmatch(r"[A-Za-z0-9_.\\-/]+", ref):
        raise DispatchError("Invalid git ref")
    if not isinstance(inputs, Mapping) or any(
        not isinstance(k, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,63}", k)
        or not isinstance(v, str) or len(v) > 1024
        for k, v in inputs.items()
    ):
        raise DispatchError("Workflow inputs must be short string key/value pairs")
    missing = set(policy.required_inputs) - set(inputs)
    if missing:
        raise DispatchError("Missing required workflow inputs")
    unknown = set(inputs) - (set(policy.required_inputs) | set(policy.input_allowlists)
                             | ({policy.confirmation_input} if policy.confirmation_input else set()))
    if unknown:
        raise DispatchError("Workflow input is not declared in policy")
    for key, choices in policy.input_allowlists.items():
        if key in inputs and inputs[key] not in choices:
            raise DispatchError("Workflow input is outside its policy allowlist")
    if policy.confirmation_input:
        if inputs.get(policy.confirmation_input) != policy.confirmation_value:
            raise DispatchError("Exact workflow confirmation input is required")
    if authorize:
        if policy.confirmation_value and confirmation != policy.confirmation_value:
            raise DispatchError("Exact operator confirmation is required")
    elif confirmation is not None:
        raise DispatchError("Confirmation is accepted only with explicit authorization")


class GitHubActionsAdapter:
    """Minimal GitHub REST adapter; the bearer token is never exposed."""

    def __init__(self, token: str, api_url: str = "https://api.github.com",
                 timeout: int = 20):
        if not token:
            raise DispatchError("A runtime GitHub token is required")
        self._token = token
        self._api_url = api_url.rstrip("/")
        self._timeout = timeout

    def _request(self, method: str, path: str,
                 payload: Mapping[str, Any] | None = None) -> tuple[int, Any]:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request = urllib.request.Request(
            self._api_url + path, data=data, method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": "Bearer " + self._token,
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
                "User-Agent": "fork-sync-all-workflow-dispatch-engine",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                body = response.read()
                return response.status, json.loads(body) if body else None
        except urllib.error.HTTPError as exc:
            # Do not surface provider response bodies: they may contain sensitive data.
            if exc.code == 404:
                raise DispatchError(
                    "Workflow not found or unavailable on the repository default branch"
                ) from None
            if exc.code in (401, 403):
                raise DispatchError("GitHub rejected workflow dispatch authorization") from None
            if exc.code == 422:
                raise DispatchError("GitHub rejected the workflow ref or inputs") from None
            raise DispatchError(f"GitHub workflow API request failed (HTTP {exc.code})") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise DispatchError("GitHub workflow API request failed; outcome may be unknown") from None

    def dispatch(self, repository: str, workflow: str, ref: str,
                 inputs: Mapping[str, str]) -> None:
        owner, name = repository.split("/", 1)
        workflow_id = urllib.parse.quote(workflow, safe="/")
        path = f"/repos/{owner}/{name}/actions/workflows/{workflow_id}/dispatches"
        status, _ = self._request("POST", path, {"ref": ref, "inputs": dict(inputs)})
        if status != 204:
            raise DispatchError("GitHub did not confirm workflow dispatch")

    def find_recent_run(self, repository: str, workflow: str, ref: str,
                        not_before: datetime) -> dict[str, Any] | None:
        owner, name = repository.split("/", 1)
        workflow_id = urllib.parse.quote(workflow, safe="/")
        query = urllib.parse.urlencode({
            "event": "workflow_dispatch", "branch": ref, "per_page": "20"
        })
        _, body = self._request(
            "GET", f"/repos/{owner}/{name}/actions/workflows/{workflow_id}/runs?{query}"
        )
        if not isinstance(body, dict):
            return None
        candidates = []
        for run in body.get("workflow_runs", []):
            try:
                created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
            except (KeyError, ValueError, TypeError):
                continue
            if created >= not_before and run.get("event") == "workflow_dispatch":
                candidates.append(run)
        # Only return a unique candidate; never guess which run belongs to this request.
        if len(candidates) != 1:
            return None
        run = candidates[0]
        return {key: run.get(key) for key in (
            "id", "html_url", "status", "conclusion", "head_branch", "head_sha"
        )}


def dispatch_workflow(policy: WorkflowPolicy, adapter: GitHubActionsAdapter,
                      ref: str, inputs: Mapping[str, str], *, authorize: bool = False,
                      confirmation: str | None = None,
                      now: datetime | None = None) -> dict[str, Any]:
    validate_request(policy, ref, inputs, authorize, confirmation)
    requested_at = now or datetime.now(timezone.utc)
    result = {
        "accepted": False,
        "mode": "live" if authorize else "dry-run",
        "repository": policy.repository,
        "workflow": policy.workflow,
        "ref": ref,
        "requested_at": requested_at.isoformat(),
        "protected": policy.protected,
        "run": None,
    }
    if not authorize:
        result["accepted"] = True
        return result
    adapter.dispatch(policy.repository, policy.workflow, ref, inputs)
    result["accepted"] = True
    # GitHub's dispatch endpoint returns 204, not a run ID. Correlation is best-effort.
    try:
        result["run"] = adapter.find_recent_run(
            policy.repository, policy.workflow, ref, requested_at
        )
    except DispatchError:
        result["run"] = None
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", default="config/workflow-dispatch-policy.json")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow", required=True, help="Workflow file path or numeric ID")
    parser.add_argument("--ref", required=True)
    parser.add_argument("--input", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--authorize-dispatch", action="store_true",
                        help="Allow a real workflow dispatch; otherwise dry-run")
    parser.add_argument("--confirm", help="Exact policy-defined operator confirmation")
    args = parser.parse_args(argv)
    inputs: dict[str, str] = {}
    for entry in args.input:
        if "=" not in entry:
            parser.error("--input must use KEY=VALUE")
        key, value = entry.split("=", 1)
        if key in inputs:
            parser.error("Duplicate workflow input")
        inputs[key] = value
    try:
        policy = load_policy(args.policy, args.repository, args.workflow)
        validate_request(policy, args.ref, inputs, args.authorize_dispatch, args.confirm)
        if not args.authorize_dispatch:
            result = dispatch_workflow(policy, None, args.ref, inputs)  # type: ignore[arg-type]
        else:
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
            adapter = GitHubActionsAdapter(token or "")
            result = dispatch_workflow(
                policy, adapter, args.ref, inputs, authorize=True, confirmation=args.confirm
            )
        print(json.dumps(result, sort_keys=True))
        return 0
    except DispatchError as exc:
        print(f"workflow-dispatch: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
