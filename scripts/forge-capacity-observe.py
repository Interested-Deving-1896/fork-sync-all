#!/usr/bin/env python3
"""Observe forge runner usage and emit a governor-compatible snapshot.

GitHub does not expose a personal-account hosted-runner capacity endpoint.  For
an organization, the closest reliable signal is the organization Actions run
stream plus each active run's jobs.  Counting jobs with an assigned runner
avoids treating GitHub's occasionally stale ``in_progress`` run records as
real capacity consumers.

Other forges are observed through ``scripts/includes/platform-adapter.sh``;
this command intentionally implements only the GitHub organization signal.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import yaml


class ObservationError(RuntimeError):
    """The requested capacity signal could not be observed safely."""


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def get_json(url: str, token: str) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": os.getenv("GITHUB_API_VERSION", "2026-03-10"),
            "User-Agent": "fork-sync-all-capacity-observer",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except (OSError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
        raise ObservationError(f"GitHub capacity query failed for {url}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ObservationError(f"GitHub returned a non-object for {url}")
    return payload


def paginated(url: str, field: str, token: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    page = 1
    while True:
        separator = "&" if "?" in url else "?"
        payload = get_json(f"{url}{separator}per_page=100&page={page}", token)
        batch = payload.get(field, [])
        if not isinstance(batch, list):
            raise ObservationError(f"GitHub response field {field!r} is not a list")
        rows.extend(row for row in batch if isinstance(row, dict))
        if len(batch) < 100:
            return rows
        page += 1


def configured_limit(config_path: Path, platform: str) -> int | None:
    with config_path.open(encoding="utf-8") as handle:
        config = yaml.safe_load(handle) or {}
    value = (((config.get("platforms") or {}).get(platform) or {}).get("fallback") or {}).get("total")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ObservationError(f"invalid {platform} fallback capacity in {config_path}")
    return value


def managed_repositories(registry_path: Path, owner: str) -> list[str]:
    """Return enabled repositories in ``owner`` from the template registry."""
    with registry_path.open(encoding="utf-8") as handle:
        registry = yaml.safe_load(handle) or {}
    consumers = registry.get("consumers", [])
    if not isinstance(consumers, list):
        raise ObservationError(f"consumers in {registry_path} must be a list")
    repositories = {f"{owner}/fork-sync-all"}
    for entry in consumers:
        if not isinstance(entry, dict) or entry.get("disabled") is True:
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            continue
        slug = name if "/" in name else f"{owner}/{name}"
        if slug.split("/", 1)[0] == owner:
            repositories.add(slug)
    return sorted(repositories)


def summarize_runs(
    active_runs: list[dict[str, Any]],
    queued_runs: list[dict[str, Any]],
    token: str,
    total: int | None,
    scope: str,
    max_run_age_seconds: int,
    source: str,
    confidence: str,
    api: str,
    repository_count: int | None = None,
    repository_failures: int = 0,
) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(seconds=max_run_age_seconds)
    recent_runs = [run for run in active_runs if (parse_time(run.get("created_at")) or now) >= cutoff]
    recent_queued_runs = [
        run for run in queued_runs if (parse_time(run.get("created_at")) or now) >= cutoff
    ]

    running = 0
    nested_queued = 0
    queued_times = [parse_time(run.get("created_at")) for run in recent_queued_runs]
    for run in recent_runs:
        jobs_url = run.get("jobs_url")
        if not isinstance(jobs_url, str) or not jobs_url:
            repository = ((run.get("repository") or {}).get("full_name"))
            run_id = run.get("id")
            if not repository or not run_id:
                continue
            jobs_url = f"{api.rstrip('/')}/repos/{repository}/actions/runs/{run_id}/jobs"
        for job in paginated(jobs_url, "jobs", token):
            status = job.get("status")
            runner_id = int(job.get("runner_id") or 0)
            if status == "in_progress" and runner_id:
                running += 1
            elif status in {"queued", "waiting", "pending"} and not runner_id:
                nested_queued += 1
                queued_times.append(parse_time(job.get("started_at")) or parse_time(job.get("created_at")))

    valid_times = [value for value in queued_times if value is not None]
    oldest_age = max(0, int((now - min(valid_times)).total_seconds())) if valid_times else None
    return {
        "platform": "github",
        "scope": scope,
        "total": total,
        "running": running,
        "queued": len(recent_queued_runs) + nested_queued,
        "oldest_age_seconds": oldest_age,
        "confidence": confidence,
        "source": source,
        "observed_at": now.isoformat().replace("+00:00", "Z"),
        "active_runs_scanned": len(recent_runs),
        "stale_runs_ignored": (
            len(active_runs) - len(recent_runs)
            + len(queued_runs) - len(recent_queued_runs)
        ),
        "repository_count": repository_count,
        "repository_failures": repository_failures,
    }


def observe_github(
    scope: str,
    token: str,
    total: int | None,
    max_run_age_seconds: int,
    api: str = "https://api.github.com",
) -> dict[str, Any]:
    encoded_scope = urllib.parse.quote(scope, safe="")
    base = f"{api.rstrip('/')}/orgs/{encoded_scope}/actions/runs"
    active_runs = paginated(f"{base}?status=in_progress", "workflow_runs", token)
    queued_runs = paginated(f"{base}?status=queued", "workflow_runs", token)
    return summarize_runs(
        active_runs, queued_runs, token, total, scope, max_run_age_seconds,
        "github-org-assigned-jobs", "medium", api,
    )


def observe_github_repositories(
    repositories: list[str],
    scope: str,
    token: str,
    total: int | None,
    max_run_age_seconds: int,
    api: str = "https://api.github.com",
    workers: int = 8,
) -> dict[str, Any]:
    active_runs: list[dict[str, Any]] = []
    queued_runs: list[dict[str, Any]] = []
    failures = 0
    def fetch(repository: str) -> tuple[str, list[dict[str, Any]] | None, str | None]:
        encoded = "/".join(urllib.parse.quote(part, safe="") for part in repository.split("/", 1))
        try:
            # Only the newest page is needed: queued/active runs are scheduler
            # state, not history. Paginating completed history would turn one
            # bounded observation into thousands of unrelated API calls.
            payload = get_json(f"{api.rstrip('/')}/repos/{encoded}/actions/runs?per_page=100", token)
            raw_runs = payload.get("workflow_runs", [])
            if not isinstance(raw_runs, list):
                raise ObservationError("workflow_runs is not a list")
            runs = [run for run in raw_runs if isinstance(run, dict)]
        except ObservationError as exc:
            return repository, None, str(exc)
        return repository, runs, None

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
        results = list(executor.map(fetch, repositories))
    for repository, runs, error in results:
        if error is not None or runs is None:
            failures += 1
            print(f"[forge-capacity-observe][warn] {repository}: {error}", file=sys.stderr)
            continue
        active_runs.extend(run for run in runs if run.get("status") == "in_progress")
        queued_runs.extend(run for run in runs if run.get("status") in {"queued", "waiting", "pending"})
    if failures == len(repositories):
        raise ObservationError("no managed repositories could be observed")
    return summarize_runs(
        active_runs, queued_runs, token, total, scope, max_run_age_seconds,
        "github-managed-repository-jobs", "low", api,
        repository_count=len(repositories), repository_failures=failures,
    )


def parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parents[1]
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--platform", default="github", choices=("github",))
    result.add_argument("--scope", required=True, help="GitHub organization to observe")
    result.add_argument("--config", default=str(root / "config/forge-capacity.yml"))
    result.add_argument("--total", type=int, help="override the configured concurrency ceiling")
    result.add_argument("--max-run-age-seconds", type=int, default=21600)
    result.add_argument("--api", default=os.getenv("GH_API", "https://api.github.com"))
    result.add_argument("--registry", help="managed-repository YAML fallback for personal accounts")
    result.add_argument("--workers", type=int, default=8, help="bounded parallel repository queries")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    token = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if not token:
        print("[forge-capacity-observe][error] GH_TOKEN is required", file=sys.stderr)
        return 2
    if args.total is not None and args.total < 0:
        print("[forge-capacity-observe][error] --total must be non-negative", file=sys.stderr)
        return 2
    try:
        total = args.total if args.total is not None else configured_limit(Path(args.config), args.platform)
        try:
            observation = observe_github(args.scope, token, total, args.max_run_age_seconds, args.api)
        except ObservationError:
            if not args.registry:
                raise
            repositories = managed_repositories(Path(args.registry), args.scope)
            observation = observe_github_repositories(
                repositories, args.scope, token, total, args.max_run_age_seconds, args.api, args.workers
            )
    except (OSError, ObservationError) as exc:
        print(f"[forge-capacity-observe][error] {exc}", file=sys.stderr)
        return 2
    json.dump(observation, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
