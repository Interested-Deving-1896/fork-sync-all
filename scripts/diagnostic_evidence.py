"""Provider-neutral, read-only diagnostic evidence primitives.

This module deliberately performs no network access and grants no authority to
rerun workflows, modify repositories, or publish raw logs. Provider adapters
should normalize retrieved data into these types after verifying provenance.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
import hashlib
import json
import re
from typing import Any, Iterable, Mapping


class RetrievalStatus(str, Enum):
    SUCCESS = "success"
    PARTIAL = "partial"
    UNAVAILABLE = "unavailable"
    UNSUPPORTED = "unsupported"
    EXPIRED = "expired"
    FAILED = "failed"


class EvidenceError(ValueError):
    """Base class for invalid or unsafe evidence."""


class EvidenceCorrelationError(EvidenceError):
    """Raised when evidence cannot be tied to the requested execution."""


_REQUIRED_PROVENANCE = ("repository", "run_id", "attempt", "head_sha")


@dataclass(frozen=True)
class Provenance:
    repository: str
    run_id: int
    attempt: int
    head_sha: str
    branch: str | None = None
    ref: str | None = None
    pull_request: int | None = None
    job_id: int | None = None
    check_run_id: int | None = None

    def __post_init__(self) -> None:
        if not self.repository or "/" not in self.repository:
            raise EvidenceError("repository must be an owner/name identifier")
        if self.run_id <= 0 or self.attempt <= 0:
            raise EvidenceError("run_id and attempt must be positive integers")
        if not re.fullmatch(r"[0-9a-fA-F]{40,64}", self.head_sha):
            raise EvidenceError("head_sha must be a full hexadecimal commit SHA")
        for name in ("job_id", "check_run_id", "pull_request"):
            value = getattr(self, name)
            if value is not None and value <= 0:
                raise EvidenceError(f"{name} must be positive when supplied")


@dataclass(frozen=True)
class EvidenceRecord:
    schema_version: str
    source: str
    provenance: Provenance
    status: RetrievalStatus
    retrieved_at: str
    records: tuple[Mapping[str, Any], ...] = ()
    errors: tuple[str, ...] = ()
    pages_read: int = 0
    pages_expected: int | None = None
    redaction_applied: bool = False

    def __post_init__(self) -> None:
        if self.schema_version != "1.0":
            raise EvidenceError("unsupported evidence schema_version")
        if not self.source.strip():
            raise EvidenceError("source is required")
        try:
            parsed = datetime.fromisoformat(self.retrieved_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise EvidenceError("retrieved_at must be an ISO-8601 timestamp") from exc
        if parsed.tzinfo is None:
            raise EvidenceError("retrieved_at must include a timezone")
        if self.pages_read < 0 or (self.pages_expected is not None and self.pages_expected < 0):
            raise EvidenceError("page counts cannot be negative")
        if self.pages_expected is not None and self.pages_read > self.pages_expected:
            raise EvidenceError("pages_read cannot exceed pages_expected")
        if self.status == RetrievalStatus.SUCCESS and self.pages_expected is not None and self.pages_read != self.pages_expected:
            raise EvidenceError("successful evidence must account for every expected page")
        if self.status == RetrievalStatus.PARTIAL and not self.errors:
            raise EvidenceError("partial evidence must explain its incompleteness")
        if self.status == RetrievalStatus.SUCCESS and self.errors:
            raise EvidenceError("successful evidence cannot carry retrieval errors")


def verify_correlation(expected: Provenance, observed: Mapping[str, Any]) -> None:
    """Require exact run/attempt/SHA identity; never infer or fall back."""
    expected_values = {
        "repository": expected.repository,
        "run_id": expected.run_id,
        "attempt": expected.attempt,
        "head_sha": expected.head_sha.lower(),
    }
    for key, value in expected_values.items():
        actual = observed.get(key)
        if actual is None:
            raise EvidenceCorrelationError(f"observed provenance is missing {key}")
        if key == "head_sha" and isinstance(actual, str):
            actual = actual.lower()
        if actual != value:
            raise EvidenceCorrelationError(f"provenance mismatch for {key}")
    for key in ("branch", "ref", "pull_request", "job_id", "check_run_id"):
        expected_value = getattr(expected, key)
        if expected_value is not None and observed.get(key) != expected_value:
            raise EvidenceCorrelationError(f"provenance mismatch for {key}")


def normalize_annotation(
    annotation: Mapping[str, Any], *, check_run_id: int, head_sha: str
) -> dict[str, Any]:
    """Normalize a GitHub check annotation without losing its source identity."""
    if annotation.get("check_run_id") != check_run_id:
        raise EvidenceCorrelationError("annotation check_run_id mismatch")
    actual_sha = annotation.get("head_sha")
    if not isinstance(actual_sha, str) or actual_sha.lower() != head_sha.lower():
        raise EvidenceCorrelationError("annotation head_sha mismatch")
    path = annotation.get("path")
    if not isinstance(path, str) or not path or path.startswith("/") or ".." in path.split("/"):
        raise EvidenceError("annotation path must be a safe repository-relative path")
    level = annotation.get("annotation_level")
    if level not in {"notice", "warning", "failure"}:
        raise EvidenceError("annotation_level must be notice, warning, or failure")
    start = annotation.get("start_line")
    end = annotation.get("end_line")
    if start is not None and (not isinstance(start, int) or start < 1):
        raise EvidenceError("start_line must be a positive integer")
    if end is not None and (not isinstance(end, int) or end < 1):
        raise EvidenceError("end_line must be a positive integer")
    if start is not None and end is not None and end < start:
        raise EvidenceError("end_line cannot precede start_line")
    return {
        "check_run_id": check_run_id,
        "head_sha": head_sha.lower(),
        "path": path,
        "start_line": start,
        "end_line": end,
        "annotation_level": level,
        "title": redact_text(str(annotation.get("title") or "")),
        "message": redact_text(str(annotation.get("message") or "")),
    }


# Redact common credentials and credential-bearing URLs before excerpts are shown.
_REDACTION_PATTERNS = (
    (re.compile(r"(?i)(authorization\s*[:=]\s*(?:bearer|token)\s+)[^\s,;]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)\bgh[pousr]_[A-Za-z0-9_]{20,}\b"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"(?i)\bgithub_pat_[A-Za-z0-9_]{20,}\b"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"(?i)(https?://[^/\s:@]+):([^@\s]+)@"), r"\1:[REDACTED]@"),
    (re.compile(r"(?i)(https?://[^\s?]+)\?([^\s#]+)"), r"\1?[REDACTED_QUERY]"),
)


def redact_text(value: str) -> str:
    result = value
    for pattern, replacement in _REDACTION_PATTERNS:
        result = pattern.sub(replacement, result)
    return result


def redact_value(value: Any) -> Any:
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, tuple):
        return [redact_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): redact_value(item) for key, item in value.items()}
    return value


def canonical_digest(value: Any) -> str:
    """SHA-256 over deterministic, redacted JSON; raw secrets never enter digest input."""
    safe = redact_value(value)
    encoded = json.dumps(safe, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def build_audit_report(evidence: Iterable[EvidenceRecord]) -> dict[str, Any]:
    items = list(evidence)
    if not items:
        raise EvidenceError("at least one evidence record is required")
    serialized = []
    complete = True
    for item in items:
        data = asdict(item)
        data["status"] = item.status.value
        data["records"] = [redact_value(dict(row)) for row in item.records]
        data["errors"] = [redact_text(error) for error in item.errors]
        data["redaction_applied"] = True
        if item.status != RetrievalStatus.SUCCESS:
            complete = False
        serialized.append(data)
    report = {
        "schema_version": "1.0",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "complete": complete,
        "evidence": serialized,
    }
    report["content_sha256"] = canonical_digest(
        {"schema_version": report["schema_version"], "complete": complete, "evidence": serialized}
    )
    return report
