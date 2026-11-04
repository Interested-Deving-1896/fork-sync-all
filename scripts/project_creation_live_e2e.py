"""Protected live E2E runner for the actual Project Creation Engine.

This entry point is intentionally narrow: one private disposable GitHub
repository, one pinned local template bundle, a durable SQLite journal, exact
confirmation, and immutable-ID-checked cleanup. It never dispatches mirrors.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import sys
from typing import Any

from scripts.project_creation_engine import create_project, validate_project_spec
from scripts.project_creation_github_adapter import GitHubRepositoryAdapter
from scripts.project_creation_journal import SQLiteCreationJournal
from scripts.project_template_bundle import resolve_template_bundle
from scripts.project_template_registry import load_registry, resolve_template


CANONICAL_REPOSITORY = "Interested-Deving-1896/fork-sync-all"
CONFIRMATION = "CREATE-AND-DELETE"


def disposable_repository_name(run_id: str, run_attempt: str) -> str:
    if not re.fullmatch(r"[0-9]{1,20}", str(run_id)) or not re.fullmatch(
        r"[0-9]{1,5}", str(run_attempt)
    ):
        raise ValueError("workflow run identifiers must be numeric")
    return f"fsa-live-e2e-{run_id}-{run_attempt}"


def run_live_e2e(
    *,
    repository: str,
    confirmation: str,
    owner: str,
    token: str,
    run_id: str,
    run_attempt: str,
    repository_root: str | Path,
    journal_path: str | Path,
    adapter: Any | None = None,
) -> dict[str, Any]:
    """Execute the real engine and always attempt identity-safe cleanup."""
    if repository != CANONICAL_REPOSITORY:
        raise PermissionError("live project-creation E2E is restricted to the canonical repository")
    if confirmation != CONFIRMATION:
        raise PermissionError("exact live-test confirmation is required")
    if not token or not token.strip():
        raise ValueError("the protected runtime token is required")

    name = disposable_repository_name(run_id, run_attempt)
    root = Path(repository_root).resolve(strict=True)
    templates = load_registry(root / "config" / "project-template-registry.yml")
    template = resolve_template(templates, "generic-project", "1.0.0")
    bundle = resolve_template_bundle(template, root)
    spec = validate_project_spec({
        "name": name,
        "provider": "github",
        "template_id": template.template_id,
        "template_version": template.version,
        "description": "Disposable Fork-Sync-All project-creation engine E2E",
        "visibility": "private",
    })
    provider = adapter or GitHubRepositoryAdapter(
        owner, token=token, owner_type="org", timeout=20.0
    )
    if getattr(provider, "provider_id", None) != "github":
        raise ValueError("live E2E requires the GitHub provider adapter")
    cleanup = getattr(provider, "cleanup_created_repository", None)
    if not callable(cleanup):
        raise ValueError("adapter must provide immutable-ID-safe disposable cleanup")

    # Preflight happens before the engine's first mutation. Never reuse a name.
    if provider.repository_exists(name):
        raise FileExistsError("the uniquely named disposable target already exists")
    key = f"fsa-live-e2e:{run_id}:{run_attempt}"
    journal = SQLiteCreationJournal(journal_path)
    outcome: dict[str, Any] | None = None
    cleanup_error: Exception | None = None
    try:
        outcome = create_project(
            spec,
            template,
            provider,
            idempotency_key=key,
            dry_run=False,
            authorize_mutation=True,
            template_bundle=bundle,
            journal=journal,
        )
    finally:
        try:
            if cleanup(name) is not True:
                raise RuntimeError("adapter did not confirm cleanup of the disposable repository")
        except Exception as exc:  # report a sanitized failure; never include token/provider body
            cleanup_error = exc

    if cleanup_error is not None:
        raise RuntimeError(
            f"disposable repository cleanup failed for {owner}/{name}; inspect and delete it manually"
        ) from None
    entry = journal.get(key)
    if (
        not isinstance(outcome, dict)
        or outcome.get("ok") is not True
        or outcome.get("status") != "verified"
        or outcome.get("repository") != name
        or outcome.get("journal_state") != "verified"
        or not entry
        or entry.get("state") != "verified"
        or entry.get("repository_name") != name
    ):
        raise RuntimeError(
            "Project Creation Engine did not reach verified; target cleanup was attempted. "
            "Inspect the run and journal before any retry."
        )
    return {
        "status": "verified",
        "repository": f"{owner}/{name}",
        "journal_state": entry["state"],
        "cleanup": "completed",
    }


def main() -> int:
    required = (
        "GITHUB_REPOSITORY",
        "GITHUB_REPOSITORY_OWNER",
        "PROJECT_CREATION_E2E_TOKEN",
        "INPUT_CONFIRM_LIVE_TEST",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "RUNNER_TEMP",
    )
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        print("Missing required live E2E environment: " + ", ".join(missing), file=sys.stderr)
        return 2
    try:
        result = run_live_e2e(
            repository=os.environ["GITHUB_REPOSITORY"],
            confirmation=os.environ["INPUT_CONFIRM_LIVE_TEST"],
            owner=os.environ["GITHUB_REPOSITORY_OWNER"],
            token=os.environ["PROJECT_CREATION_E2E_TOKEN"],
            run_id=os.environ["GITHUB_RUN_ID"],
            run_attempt=os.environ["GITHUB_RUN_ATTEMPT"],
            repository_root=Path(__file__).resolve().parents[1],
            journal_path=Path(os.environ["RUNNER_TEMP"]) / "project-creation-e2e.sqlite3",
        )
    except Exception as exc:
        # Exception messages are intentionally sanitized by the adapter/runner.
        print(f"::error::{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    print(f"Engine result: {result['status']}; journal: {result['journal_state']}")
    print("Disposable repository cleanup completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
