"""Durable, fail-closed idempotency journal for project creation.

The journal stores request fingerprints and lifecycle states, never provider
credentials or arbitrary provider response payloads. An interrupted mutation
is left for reconciliation rather than automatically replayed.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from typing import Any, Mapping

from scripts.project_creation_engine import (
    ProjectCreationAdapter,
    ProjectSpecError,
    ProjectSpec,
    Template,
    build_plan,
)


class JournalError(RuntimeError):
    """Base error for durable creation journal failures."""


class IdempotencyConflict(JournalError):
    """An idempotency key was reused for a different creation request."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _fingerprint(plan: Any) -> str:
    payload = {
        "provider": plan.provider,
        "repository_name": plan.repository_name,
        "template_id": plan.template_id,
        "template_version": plan.template_version,
        "description": plan.description,
        "visibility": plan.visibility,
        "required_capabilities": list(plan.required_capabilities),
        "template_sha256": dict(sorted(plan.template_sha256.items())),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


class SQLiteCreationJournal:
    """SQLite-backed state journal suitable for a persistent local data path.

    A database on ephemeral runner storage is not durable across runner loss.
    Production callers must supply a persistent, access-controlled path and
    protect it with normal filesystem/database backup controls.
    """

    def __init__(self, path: str | Path):
        self.path = Path(path)
        if str(path) == ":memory:":
            raise ValueError(
                "SQLiteCreationJournal requires a persistent file path; "
                "separate per-operation connections cannot safely use :memory:"
            )
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.database = str(self.path)
        with self._connection() as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=FULL")
            db.execute(
                """
                CREATE TABLE IF NOT EXISTS project_creation_journal (
                    idempotency_key TEXT PRIMARY KEY,
                    request_fingerprint TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN (
                        'prepared', 'creation_started', 'created',
                        'verified', 'reconciliation_required'
                    )),
                    provider TEXT NOT NULL,
                    repository_name TEXT NOT NULL,
                    template_id TEXT NOT NULL,
                    template_version TEXT NOT NULL,
                    error_code TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )

    @contextmanager
    def _connection(self):
        db = sqlite3.connect(self.database, timeout=10, isolation_level=None)
        try:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA busy_timeout=10000")
            yield db
        finally:
            db.close()

    @staticmethod
    def _validate_key(key: str) -> None:
        if not isinstance(key, str) or not key.strip() or any(c in key for c in "\r\n\x00"):
            raise ProjectSpecError("idempotency_key must be non-empty and contain no control characters")

    def get(self, key: str) -> Mapping[str, Any] | None:
        self._validate_key(key)
        with self._connect() as db:
            row = db.execute(
                "SELECT * FROM project_creation_journal WHERE idempotency_key = ?", (key,)
            ).fetchone()
        return dict(row) if row is not None else None

    def prepare(self, key: str, plan: Any) -> Mapping[str, Any]:
        self._validate_key(key)
        fingerprint = _fingerprint(plan)
        now = _now()
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute(
                """
                INSERT OR IGNORE INTO project_creation_journal
                (idempotency_key, request_fingerprint, state, provider, repository_name,
                 template_id, template_version, created_at, updated_at)
                VALUES (?, ?, 'prepared', ?, ?, ?, ?, ?, ?)
                """,
                (key, fingerprint, plan.provider, plan.repository_name, plan.template_id,
                 plan.template_version, now, now),
            )
            row = db.execute(
                "SELECT * FROM project_creation_journal WHERE idempotency_key = ?", (key,)
            ).fetchone()
            if row["request_fingerprint"] != fingerprint:
                db.execute("ROLLBACK")
                raise IdempotencyConflict("idempotency key is already bound to a different request")
            db.execute("COMMIT")
        return dict(row)

    def advance(self, key: str, expected: str, target: str, error_code: str | None = None) -> bool:
        self._validate_key(key)
        now = _now()
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            cursor = db.execute(
                """
                UPDATE project_creation_journal
                SET state = ?, error_code = ?, updated_at = ?
                WHERE idempotency_key = ? AND state = ?
                """,
                (target, error_code, now, key, expected),
            )
            db.execute("COMMIT")
        return cursor.rowcount == 1

    def require_reconciliation(self, key: str, error_code: str) -> None:
        self._validate_key(key)
        now = _now()
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute(
                """
                UPDATE project_creation_journal
                SET state = 'reconciliation_required', error_code = ?, updated_at = ?
                WHERE idempotency_key = ? AND state IN ('creation_started', 'created')
                """,
                (error_code, now, key),
            )
            db.execute("COMMIT")


def create_project_with_journal(
    spec: ProjectSpec,
    template: Template,
    adapter: ProjectCreationAdapter,
    journal: SQLiteCreationJournal,
    *,
    idempotency_key: str,
    dry_run: bool = True,
    authorize_mutation: bool = False,
    template_bundle: Any | None = None,
) -> Mapping[str, Any]:
    """Create and verify once, recording durable state before provider mutation.

    Ambiguous or interrupted provider operations are never retried automatically.
    Reconciliation is required before an operator can safely decide what to do.
    """
    SQLiteCreationJournal._validate_key(idempotency_key)
    adapter_provider = getattr(adapter, "provider_id", None)
    if (
        not isinstance(adapter_provider, str)
        or not adapter_provider
        or not re.fullmatch(r"[a-z][a-z0-9_-]{0,49}", adapter_provider)
        or adapter_provider != spec.provider
    ):
        raise ProjectSpecError("project provider does not match a valid adapter provider")
    plan = build_plan(spec, template, adapter.capabilities(), template_bundle=template_bundle)
    if dry_run:
        return {"ok": True, "status": "planned", "simulated": True, "plan": plan.__dict__}
    if not authorize_mutation:
        raise PermissionError("repository creation requires authorize_mutation=True")

    entry = journal.prepare(idempotency_key, plan)
    if entry["state"] == "verified":
        return {
            "ok": True, "status": "verified", "simulated": False, "replayed": True,
            "provider": plan.provider, "repository": plan.repository_name,
            "journal_state": "verified", "mirror_propagation": "not_requested",
        }
    if entry["state"] != "prepared":
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": entry.get("error_code") or "operation_already_started",
            "journal_state": entry["state"], "mirror_propagation": "not_requested",
        }

    if adapter.repository_exists(spec.name):
        return {
            "ok": False, "status": "conflict", "error_code": "target_exists",
            "repository": spec.name, "journal_state": "prepared",
        }

    # Compare-and-swap ensures concurrent callers cannot both enter mutation.
    if not journal.advance(idempotency_key, "prepared", "creation_started"):
        current = journal.get(idempotency_key) or {}
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "operation_already_started",
            "journal_state": current.get("state", "unknown"),
            "mirror_propagation": "not_requested",
        }

    try:
        created = adapter.create_from_template(plan, idempotency_key)
    except Exception:
        journal.require_reconciliation(idempotency_key, "provider_call_interrupted")
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "provider_call_interrupted",
            "message": "Provider outcome is ambiguous; inspect the target before retrying.",
            "mirror_propagation": "not_requested",
        }
    if not isinstance(created, Mapping):
        journal.require_reconciliation(idempotency_key, "invalid_creation_evidence")
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "invalid_creation_evidence",
            "mirror_propagation": "not_requested",
        }
    if not journal.advance(idempotency_key, "creation_started", "created"):
        journal.require_reconciliation(idempotency_key, "journal_transition_conflict")
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "journal_transition_conflict",
            "mirror_propagation": "not_requested",
        }

    try:
        verified = adapter.verify_created_project(spec.name, template)
    except Exception:
        journal.require_reconciliation(idempotency_key, "verification_interrupted")
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "verification_interrupted",
            "message": "Creation may have succeeded but verification was interrupted.",
            "mirror_propagation": "not_requested",
        }
    if not isinstance(verified, Mapping) or verified.get("metadata") is not True or verified.get("seeded_files") is not True:
        journal.require_reconciliation(idempotency_key, "verification_incomplete")
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "verification_incomplete",
            "message": "Created project could not be fully verified; inspect the target before retrying.",
            "mirror_propagation": "not_requested",
        }
    if not journal.advance(idempotency_key, "created", "verified"):
        journal.require_reconciliation(idempotency_key, "journal_transition_conflict")
        return {
            "ok": False, "status": "reconciliation_required", "simulated": False,
            "error_code": "journal_transition_conflict",
            "mirror_propagation": "not_requested",
        }
    return {
        "ok": True, "status": "verified", "simulated": False,
        "provider": plan.provider, "repository": plan.repository_name,
        "journal_state": "verified", "mirror_propagation": "not_requested",
    }
