#!/usr/bin/env python3
"""Drain non-critical queued CI runs across a managed forge estate.

The command has a platform-neutral CLI and provider boundary.  GitHub is the
first provider; future GitLab/Gitea/Forgejo providers can implement the same
``list_pending`` / ``refresh`` / ``cancel`` contract without changing the
selection policy.

Structured results are written to stdout.  Human-readable logs always go to
stderr so callers can safely capture the JSON summary.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Protocol

import yaml


PENDING_STATUSES = frozenset({"pending", "queued", "requested", "waiting"})


class DrainError(RuntimeError):
    """The managed queue could not be inspected or changed safely."""


@dataclass(frozen=True)
class QueueRun:
    repository: str
    run_id: int
    workflow_name: str
    status: str
    html_url: str = ""


class QueueProvider(Protocol):
    """Minimal provider contract used by the platform-neutral drain policy."""

    def list_pending(self, repository: str) -> list[QueueRun]: ...

    def refresh(self, run: QueueRun) -> QueueRun: ...

    def cancel(self, run: QueueRun) -> None: ...


def log(message: str) -> None:
    print(f"[managed-estate-drain] {message}", file=sys.stderr)


def warn(message: str) -> None:
    print(f"[managed-estate-drain][warn] {message}", file=sys.stderr)


def load_yaml(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise DrainError(f"cannot read {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise DrainError(f"{path} must contain a YAML mapping")
    return data


def managed_repositories(registry: Path, scope: str) -> list[str]:
    """Load enabled, directly managed repositories in *scope*.

    ``protected`` entries are mirror-chain infrastructure and ``delegated``
    entries belong to another publisher.  Neither is a managed fallback
    target, so broad queue cancellation must not cross those boundaries.  The
    canonical control repository is included explicitly and protected by its
    tier-1 workflow names plus the caller's current run ID.
    """
    data = load_yaml(registry)
    consumers = data.get("consumers", [])
    if not isinstance(consumers, list):
        raise DrainError(f"consumers in {registry} must be a list")
    repositories = {f"{scope}/fork-sync-all"}
    for entry in consumers:
        if not isinstance(entry, dict) or entry.get("disabled") is True:
            continue
        if entry.get("tier", "managed") != "managed":
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        slug = name.strip() if "/" in name else f"{scope}/{name.strip()}"
        if slug.split("/", 1)[0] == scope:
            repositories.add(slug)
    return sorted(repositories)


def tier_one_workflows(tiers_path: Path) -> frozenset[str]:
    data = load_yaml(tiers_path)
    tiers = data.get("tiers", [])
    if not isinstance(tiers, list):
        raise DrainError(f"tiers in {tiers_path} must be a list")
    result: set[str] = set()
    for entry in tiers:
        if not isinstance(entry, dict) or entry.get("tier") != 1:
            continue
        name = entry.get("name")
        if isinstance(name, str) and name:
            result.add(name)
    return frozenset(result)


def parse_protected_ids(values: Iterable[str]) -> frozenset[int]:
    result: set[int] = set()
    for value in values:
        for item in value.split(","):
            item = item.strip()
            if not item:
                continue
            if not item.isdigit() or int(item) <= 0:
                raise DrainError(f"protected run ID must be a positive integer: {item!r}")
            result.add(int(item))
    return frozenset(result)


def select_runs(
    runs: Iterable[QueueRun],
    tier_one: frozenset[str],
    protected_ids: frozenset[int],
) -> tuple[list[QueueRun], list[tuple[QueueRun, str]]]:
    selected: list[QueueRun] = []
    preserved: list[tuple[QueueRun, str]] = []
    seen: set[tuple[str, int]] = set()
    for run in sorted(runs, key=lambda row: (row.repository, row.run_id)):
        key = (run.repository, run.run_id)
        if key in seen:
            continue
        seen.add(key)
        if run.status not in PENDING_STATUSES:
            preserved.append((run, f"status changed to {run.status}"))
        elif run.run_id in protected_ids:
            preserved.append((run, "explicitly protected run ID"))
        elif run.workflow_name in tier_one:
            preserved.append((run, "tier-1 workflow"))
        else:
            selected.append(run)
    return selected, preserved


class GitHubProvider:
    """GitHub Actions implementation of :class:`QueueProvider`."""

    def __init__(self, token: str, api: str = "https://api.github.com") -> None:
        self.token = token
        self.api = api.rstrip("/")
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": os.getenv("GITHUB_API_VERSION", "2026-03-10"),
            "User-Agent": "fork-sync-all-managed-estate-drain",
        }

    def _request(self, url: str, method: str = "GET") -> Any:
        request = urllib.request.Request(url, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
        except (OSError, urllib.error.HTTPError) as exc:
            raise DrainError(f"GitHub {method} failed for {url}: {exc}") from exc
        if not body:
            return {}
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise DrainError(f"GitHub returned invalid JSON for {url}") from exc

    @staticmethod
    def _queue_run(repository: str, row: dict[str, Any]) -> QueueRun:
        return QueueRun(
            repository=repository,
            run_id=int(row["id"]),
            workflow_name=str(row.get("name") or row.get("workflow_name") or ""),
            status=str(row.get("status") or ""),
            html_url=str(row.get("html_url") or ""),
        )

    def list_pending(self, repository: str) -> list[QueueRun]:
        encoded = "/".join(urllib.parse.quote(part, safe="") for part in repository.split("/", 1))
        url = f"{self.api}/repos/{encoded}/actions/runs?per_page=100"
        payload = self._request(url)
        rows = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
        if not isinstance(rows, list):
            raise DrainError(f"GitHub workflow_runs for {repository} is not a list")
        return [
            self._queue_run(repository, row)
            for row in rows
            if isinstance(row, dict) and row.get("status") in PENDING_STATUSES
        ]

    def refresh(self, run: QueueRun) -> QueueRun:
        encoded = "/".join(
            urllib.parse.quote(part, safe="") for part in run.repository.split("/", 1)
        )
        payload = self._request(f"{self.api}/repos/{encoded}/actions/runs/{run.run_id}")
        if not isinstance(payload, dict):
            raise DrainError(f"GitHub run {run.run_id} returned a non-object")
        return self._queue_run(run.repository, payload)

    def cancel(self, run: QueueRun) -> None:
        encoded = "/".join(
            urllib.parse.quote(part, safe="") for part in run.repository.split("/", 1)
        )
        self._request(
            f"{self.api}/repos/{encoded}/actions/runs/{run.run_id}/cancel",
            method="POST",
        )


def drain(
    provider: QueueProvider,
    repositories: list[str],
    tier_one: frozenset[str],
    protected_ids: frozenset[int],
    *,
    workers: int,
    dry_run: bool,
) -> tuple[dict[str, Any], bool]:
    runs: list[QueueRun] = []
    errors: list[dict[str, str]] = []
    scan_failures: set[str] = set()

    def inspect(repository: str) -> tuple[str, list[QueueRun] | None, str | None]:
        try:
            return repository, provider.list_pending(repository), None
        except DrainError as exc:
            return repository, None, str(exc)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        for repository, rows, error in executor.map(inspect, repositories):
            if error:
                warn(f"{repository}: {error}")
                errors.append({"repository": repository, "error": error})
                scan_failures.add(repository)
            elif rows:
                runs.extend(rows)

    selected, preserved = select_runs(runs, tier_one, protected_ids)
    for run, reason in preserved:
        log(f"preserve {run.repository}#{run.run_id} ({run.workflow_name}): {reason}")

    cancelled: list[QueueRun] = []
    raced: list[tuple[QueueRun, str]] = []

    def cancel_one(run: QueueRun) -> tuple[str, QueueRun, str | None]:
        if dry_run:
            return "dry-run", run, None
        try:
            current = provider.refresh(run)
            current_selected, current_preserved = select_runs([current], tier_one, protected_ids)
            if not current_selected:
                reason = current_preserved[0][1] if current_preserved else "no longer cancellable"
                return "raced", current, reason
            provider.cancel(current)
            return "cancelled", current, None
        except DrainError as exc:
            return "error", run, str(exc)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        for state, run, error in executor.map(cancel_one, selected):
            if state == "dry-run":
                log(f"[dry-run] would cancel {run.repository}#{run.run_id} ({run.workflow_name})")
            elif state == "cancelled":
                cancelled.append(run)
                log(f"cancelled {run.repository}#{run.run_id} ({run.workflow_name})")
            elif state == "raced":
                raced.append((run, error or "status changed"))
                log(f"preserve {run.repository}#{run.run_id}: {error}")
            else:
                warn(f"{run.repository}#{run.run_id}: {error}")
                errors.append(
                    {
                        "repository": run.repository,
                        "run_id": str(run.run_id),
                        "error": error or "unknown error",
                    }
                )

    summary = {
        "platform": "github",
        "dry_run": dry_run,
        "repositories_scanned": len(repositories) - len(scan_failures),
        "repositories_total": len(repositories),
        "pending_found": len(runs),
        "eligible": len(selected),
        "cancelled": len(cancelled),
        "would_cancel": len(selected) if dry_run else 0,
        "preserved": len(preserved) + len(raced),
        "protected_run_ids": sorted(protected_ids),
        "errors": errors,
        "candidates": [asdict(run) for run in selected],
    }
    return summary, bool(errors)


def parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parents[1]
    runner_temp = os.getenv("RUNNER_TEMP")
    github_run_id = os.getenv("GITHUB_RUN_ID")
    default_state = (
        str(Path(runner_temp) / f"managed-estate-drain-{github_run_id}.json")
        if runner_temp and github_run_id
        else None
    )
    default_interval = 900 if default_state else 0
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--platform", default="github", choices=("github",))
    result.add_argument("--scope", required=True, help="forge owner/group containing managed repos")
    result.add_argument("--registry", default=str(root / "config/template-consumers.yml"))
    result.add_argument("--tiers", default=str(root / "config/workflow-priority-tiers.yml"))
    result.add_argument("--protect-run-id", action="append", default=[], help="run ID(s) to preserve; repeat or use comma-separated values")
    result.add_argument("--workers", type=int, default=8, help="bounded concurrent API operations")
    result.add_argument("--api", default=os.getenv("GH_API", "https://api.github.com"))
    result.add_argument("--dry-run", action="store_true")
    result.add_argument("--summary-file", help="also write the JSON result to this path")
    result.add_argument(
        "--state-file",
        default=default_state,
        help="completed-scan marker used to throttle repeated handoffs",
    )
    result.add_argument(
        "--min-interval-seconds",
        type=int,
        default=int(os.getenv("ESTATE_DRAIN_MIN_INTERVAL_SECONDS", str(default_interval))),
        help="skip a repeated scan while the state marker is newer than this interval",
    )
    return result


def recent_state(path: Path | None, interval: int, scope: str) -> dict[str, Any] | None:
    if path is None or interval <= 0:
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict) or data.get("scope") != scope:
        return None
    completed_at = data.get("completed_at")
    if not isinstance(completed_at, (int, float)):
        return None
    age = max(0, int(time.time() - completed_at))
    return data if age < interval else None


def write_state(path: Path | None, scope: str, summary: dict[str, Any]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(
        json.dumps({"scope": scope, "completed_at": time.time(), "summary": summary}) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.workers < 1 or args.workers > 32:
        print("[managed-estate-drain][error] --workers must be between 1 and 32", file=sys.stderr)
        return 2
    if args.min_interval_seconds < 0:
        print("[managed-estate-drain][error] --min-interval-seconds must be non-negative", file=sys.stderr)
        return 2
    token = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if not token:
        print("[managed-estate-drain][error] GH_TOKEN is required", file=sys.stderr)
        return 2
    protected_values = list(args.protect_run_id)
    protected_values.append(os.getenv("PROTECTED_RUN_IDS", ""))
    try:
        protected_ids = parse_protected_ids(protected_values)
        state_path = Path(args.state_file) if args.state_file else None
        cached = recent_state(state_path, args.min_interval_seconds, args.scope)
        if cached is not None:
            previous = cached.get("summary", {})
            summary = {
                "platform": args.platform,
                "dry_run": args.dry_run,
                "skipped": "recent-estate-drain",
                "previous": previous,
            }
            rendered = json.dumps(summary, sort_keys=True)
            print(rendered)
            if args.summary_file:
                try:
                    Path(args.summary_file).write_text(rendered + "\n", encoding="utf-8")
                except OSError as exc:
                    raise DrainError(f"cannot write summary: {exc}") from exc
            log(
                f"recent drain attempt for {args.scope}; skipping repeated scan "
                f"within {args.min_interval_seconds}s interval"
            )
            return 0
        repositories = managed_repositories(Path(args.registry), args.scope)
        tier_one = tier_one_workflows(Path(args.tiers))
        provider: QueueProvider = GitHubProvider(token, args.api)
        log(
            f"platform={args.platform} repositories={len(repositories)} "
            f"workers={args.workers} dry_run={str(args.dry_run).lower()}"
        )
        summary, failed = drain(
            provider,
            repositories,
            tier_one,
            protected_ids,
            workers=args.workers,
            dry_run=args.dry_run,
        )
    except DrainError as exc:
        print(f"[managed-estate-drain][error] {exc}", file=sys.stderr)
        return 2

    rendered = json.dumps(summary, sort_keys=True)
    print(rendered)
    if args.summary_file:
        try:
            Path(args.summary_file).write_text(rendered + "\n", encoding="utf-8")
        except OSError as exc:
            print(f"[managed-estate-drain][error] cannot write summary: {exc}", file=sys.stderr)
            return 2
    # Record partial attempts too. A deleted/inaccessible consumer must not turn
    # every child handoff into another full-registry scan and exhaust the shared
    # API bucket. The JSON summary retained in the marker exposes such errors.
    if not args.dry_run:
        try:
            write_state(state_path, args.scope, summary)
        except OSError as exc:
            warn(f"cannot write throttle state: {exc}")
    log(
        f"done: pending={summary['pending_found']} eligible={summary['eligible']} "
        f"cancelled={summary['cancelled']} preserved={summary['preserved']} "
        f"errors={len(summary['errors'])}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
