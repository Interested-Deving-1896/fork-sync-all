"""Provider-neutral project creation planning primitives.

This module deliberately performs no network or provider mutations. Callers must
resolve a registered template, validate a project specification, inspect the
target provider's capabilities, and explicitly authorize execution through a
separately implemented adapter. The planner never invokes mirror propagation.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Any, Mapping, Protocol


_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$")
_PROVIDER_RE = re.compile(r"^[a-z][a-z0-9_-]{0,49}$")


class ProjectSpecError(ValueError):
    """Project specification or registry entry is invalid."""


@dataclass(frozen=True)
class Template:
    template_id: str
    version: str
    description: str
    source: str
    required_capabilities: tuple[str, ...] = ()


@dataclass(frozen=True)
class ProjectSpec:
    name: str
    provider: str
    template_id: str
    template_version: str
    description: str = ""
    visibility: str = "private"
    variables: Mapping[str, Any] | None = None


@dataclass(frozen=True)
class CreationPlan:
    provider: str
    repository_name: str
    template_id: str
    template_version: str
    description: str
    visibility: str
    required_capabilities: tuple[str, ...]
    operations: tuple[str, ...] = (
        "validate_target",
        "create_repository_from_template",
        "verify_repository_metadata",
        "verify_seeded_files",
    )
    side_effects: tuple[str, ...] = ()
    template_files: Mapping[str, str] = field(default_factory=dict)
    template_sha256: Mapping[str, str] = field(default_factory=dict)


class ProjectCreationAdapter(Protocol):
    """Provider adapter contract; implementations own provider API details."""

    provider_id: str

    def capabilities(self) -> set[str]: ...
    def repository_exists(self, name: str) -> bool: ...
    def create_from_template(self, plan: CreationPlan, idempotency_key: str) -> Mapping[str, Any]: ...
    def verify_created_project(self, name: str, template: Template) -> Mapping[str, Any]: ...


def validate_template(raw: Mapping[str, Any]) -> Template:
    if not isinstance(raw, Mapping):
        raise ProjectSpecError("template entry must be a mapping")
    template_id = raw.get("id")
    version = raw.get("version")
    description = raw.get("description")
    source = raw.get("source")
    if not isinstance(template_id, str) or not _NAME_RE.fullmatch(template_id):
        raise ProjectSpecError("template id must be a safe identifier")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ProjectSpecError("template version must use semantic x.y.z form")
    if not isinstance(description, str) or not description.strip():
        raise ProjectSpecError("template description is required")
    if not isinstance(source, str) or not source.strip() or source.startswith("-"):
        raise ProjectSpecError("template source must be a non-empty registry reference")
    capabilities = raw.get("required_capabilities", [])
    if not isinstance(capabilities, list) or any(
        not isinstance(item, str) or not _PROVIDER_RE.fullmatch(item) for item in capabilities
    ):
        raise ProjectSpecError("required_capabilities must be a list of safe capability names")
    if len(set(capabilities)) != len(capabilities):
        raise ProjectSpecError("required_capabilities must not contain duplicates")
    return Template(template_id, version, description.strip(), source.strip(), tuple(capabilities))


def validate_project_spec(raw: Mapping[str, Any]) -> ProjectSpec:
    if not isinstance(raw, Mapping):
        raise ProjectSpecError("project specification must be a mapping")
    name = raw.get("name")
    provider = raw.get("provider")
    template_id = raw.get("template_id")
    version = raw.get("template_version")
    description = raw.get("description", "")
    visibility = raw.get("visibility", "private")
    variables = raw.get("variables", {})
    if not isinstance(name, str) or not _NAME_RE.fullmatch(name):
        raise ProjectSpecError("name must be 1-100 characters: letters, digits, dot, underscore, hyphen")
    if not isinstance(provider, str) or not _PROVIDER_RE.fullmatch(provider):
        raise ProjectSpecError("provider must be a safe provider identifier")
    if not isinstance(template_id, str) or not _NAME_RE.fullmatch(template_id):
        raise ProjectSpecError("template_id must be a safe identifier")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ProjectSpecError("template_version must use semantic x.y.z form")
    if not isinstance(description, str) or len(description) > 350:
        raise ProjectSpecError("description must be a string of at most 350 characters")
    if visibility not in ("private", "public", "internal"):
        raise ProjectSpecError("visibility must be private, public, or internal")
    if not isinstance(variables, Mapping):
        raise ProjectSpecError("variables must be a mapping")
    return ProjectSpec(name, provider, template_id, version, description, visibility, dict(variables))


def build_plan(
    spec: ProjectSpec,
    template: Template,
    provider_capabilities: set[str],
    *,
    template_bundle: Any | None = None,
) -> CreationPlan:
    if spec.template_id != template.template_id or spec.template_version != template.version:
        raise ProjectSpecError("project specification does not match the selected template version")
    files: Mapping[str, str] = {}
    checksums: Mapping[str, str] = {}
    if template_bundle is not None:
        if (
            getattr(template_bundle, "template_id", None) != template.template_id
            or getattr(template_bundle, "version", None) != template.version
        ):
            raise ProjectSpecError("resolved template bundle does not match the selected template")
        candidate_files = getattr(template_bundle, "files", None)
        candidate_checksums = getattr(template_bundle, "sha256", None)
        if (
            not isinstance(candidate_files, Mapping)
            or not candidate_files
            or any(not isinstance(path, str) or not path or not isinstance(content, str)
                   for path, content in candidate_files.items())
            or not isinstance(candidate_checksums, Mapping)
            or set(candidate_checksums) != set(candidate_files)
            or any(not isinstance(path, str) or not isinstance(digest, str)
                   for path, digest in candidate_checksums.items())
        ):
            raise ProjectSpecError("resolved template bundle has invalid file or checksum mappings")
        files = dict(candidate_files)
        checksums = dict(candidate_checksums)
    missing = sorted(set(template.required_capabilities) - set(provider_capabilities))
    if missing:
        raise ProjectSpecError("provider is missing required capabilities: " + ", ".join(missing))
    return CreationPlan(
        provider=spec.provider,
        repository_name=spec.name,
        template_id=template.template_id,
        template_version=template.version,
        description=spec.description or template.description,
        visibility=spec.visibility,
        required_capabilities=template.required_capabilities,
        # No mirror, downstream, or propagation operation is ever implied.
        side_effects=(),
        template_files=files,
        template_sha256=checksums,
    )


def create_project(
    spec: ProjectSpec,
    template: Template,
    adapter: ProjectCreationAdapter,
    *,
    idempotency_key: str,
    dry_run: bool = True,
    authorize_mutation: bool = False,
    template_bundle: Any | None = None,
) -> Mapping[str, Any]:
    """Plan by default; execute only with explicit authorization.

    A provider adapter must identify itself with provider_id, implement
    idempotent create semantics using the supplied key, and return affirmative
    metadata and seeded-file verification evidence. Existing targets are never
    overwritten. Mirror propagation is intentionally outside this interface.
    """
    if not isinstance(idempotency_key, str) or not idempotency_key.strip() or any(
        char in idempotency_key for char in "\r\n\x00"
    ):
        raise ProjectSpecError("idempotency_key must be non-empty and contain no control characters")
    adapter_provider = getattr(adapter, "provider_id", None)
    if not isinstance(adapter_provider, str) or not _PROVIDER_RE.fullmatch(adapter_provider):
        raise ProjectSpecError("adapter must declare a valid provider_id")
    if adapter_provider != spec.provider:
        raise ProjectSpecError(
            f"project provider {spec.provider!r} does not match adapter provider {adapter_provider!r}"
        )
    plan = build_plan(spec, template, adapter.capabilities(), template_bundle=template_bundle)
    if dry_run:
        return {"ok": True, "status": "planned", "simulated": True, "plan": plan.__dict__}
    if not authorize_mutation:
        raise PermissionError("repository creation requires authorize_mutation=True")
    if adapter.repository_exists(spec.name):
        return {"ok": False, "status": "conflict", "error_code": "target_exists", "repository": spec.name}
    created = adapter.create_from_template(plan, idempotency_key)
    if not isinstance(created, Mapping):
        return {
            "ok": False, "status": "creation_result_invalid", "simulated": False,
            "error_code": "invalid_creation_evidence",
            "message": "Provider adapter returned invalid creation metadata.",
            "mirror_propagation": "not_requested",
        }
    verified = adapter.verify_created_project(spec.name, template)
    if not isinstance(verified, Mapping):
        verified = {}
    # Never report "verified" unless both independently required checks are
    # explicitly affirmative. Missing, false, or malformed evidence fails closed.
    if verified.get("metadata") is not True or verified.get("seeded_files") is not True:
        return {
            "ok": False,
            "status": "verification_failed",
            "simulated": False,
            "creation": dict(created),
            "verification": dict(verified),
            "error_code": "verification_incomplete",
            "message": "Created project could not be fully verified; inspect the target before retrying.",
            "mirror_propagation": "not_requested",
        }
    return {
        "ok": True,
        "status": "verified",
        "simulated": False,
        "creation": dict(created),
        "verification": dict(verified),
        "mirror_propagation": "not_requested",
    }
