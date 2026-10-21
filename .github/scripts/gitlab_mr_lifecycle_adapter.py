"""Read-only normalization for GitLab merge requests and pipelines.

This module deliberately performs no HTTP requests and no writes. A caller may
fetch GitLab data with a separately scoped read-only credential, then pass the
payloads here for provider-neutral lifecycle classification.
"""
from __future__ import annotations

from typing import Any

from pr_lifecycle_core import classify_lifecycle


ACTIVE_PIPELINE_STATES = {"created", "pending", "preparing", "running", "waiting_for_resource"}
FAILED_PIPELINE_STATES = {"failed"}
CANCELLED_PIPELINE_STATES = {"canceled", "cancelled"}
SKIPPED_PIPELINE_STATES = {"skipped"}
SUCCESS_PIPELINE_STATES = {"success"}


def normalize_pipeline(pipeline: dict[str, Any]) -> dict[str, Any]:
    """Translate one GitLab pipeline payload into normalized check evidence."""
    state = str(pipeline.get("status") or "unknown").strip().lower()
    if state in ACTIVE_PIPELINE_STATES:
        status, conclusion = "in_progress", None
    elif state in SUCCESS_PIPELINE_STATES:
        status, conclusion = "completed", "success"
    elif state in FAILED_PIPELINE_STATES:
        status, conclusion = "completed", "failure"
    elif state in CANCELLED_PIPELINE_STATES:
        status, conclusion = "completed", "cancelled"
    elif state in SKIPPED_PIPELINE_STATES:
        status, conclusion = "completed", "skipped"
    elif state == "manual":
        status, conclusion = "completed", "action_required"
    else:
        status, conclusion = "completed", "unknown"
    return {
        "name": str(pipeline.get("name") or f"GitLab pipeline {pipeline.get('id', 'unknown')}"),
        "status": status,
        "conclusion": conclusion,
        "provider_state": state,
        "web_url": pipeline.get("web_url"),
        "sha": pipeline.get("sha"),
    }


def normalize_merge_request(
    merge_request: dict[str, Any], pipelines: list[dict[str, Any]]
) -> dict[str, Any]:
    """Return provider-neutral lifecycle inputs for a GitLab merge request."""
    merge_status = str(
        merge_request.get("detailed_merge_status")
        or merge_request.get("merge_status")
        or "unknown"
    ).strip().lower()
    has_conflicts = merge_request.get("has_conflicts") is True
    if has_conflicts or merge_status in {"conflict", "conflicts", "cannot_be_merged"}:
        merge_state, mergeable = "dirty", False
    elif merge_status in {"need_rebase", "not_approved", "requested_changes", "blocked_status"}:
        merge_state, mergeable = "blocked", None
    elif merge_status in {"checking", "unchecked", "unknown"}:
        merge_state, mergeable = "unstable", None
    elif merge_status in {"cannot_be_merged_recheck", "cannot_be_merged_rechecking"}:
        merge_state, mergeable = "unstable", None
    elif merge_status in {"mergeable", "can_be_merged"}:
        merge_state, mergeable = "clean", True
    else:
        # Unknown provider values are not treated as proof of mergeability.
        merge_state, mergeable = "unstable", None

    draft = bool(
        merge_request.get("draft", merge_request.get("work_in_progress", False))
    )
    return {
        "number": merge_request.get("iid"),
        "title": merge_request.get("title"),
        "url": merge_request.get("web_url"),
        "sha": merge_request.get("sha") or merge_request.get("diff_refs", {}).get("head_sha"),
        "draft": draft,
        "merge_state": merge_state,
        "mergeable": mergeable,
        "checks": [normalize_pipeline(pipeline) for pipeline in pipelines],
    }


def classify_merge_request(
    merge_request: dict[str, Any], pipelines: list[dict[str, Any]]
) -> tuple[str, str]:
    """Classify GitLab evidence with the shared conservative lifecycle policy."""
    normalized = normalize_merge_request(merge_request, pipelines)
    return classify_lifecycle(
        checks=normalized["checks"],
        merge_state=normalized["merge_state"],
        mergeable=normalized["mergeable"],
        draft=normalized["draft"],
    )
