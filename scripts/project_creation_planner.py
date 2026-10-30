"""End-to-end, side-effect-free preparation of a project creation request.

This module joins spec validation, exact registry resolution, local bundle
integrity verification, and capability-aware planning. It does not call a
provider or create/propagate repositories.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from scripts.project_creation_engine import (
    CreationPlan,
    ProjectSpec,
    ProjectSpecError,
    Template,
    build_plan,
    validate_project_spec,
)
from scripts.project_template_bundle import TemplateBundle, resolve_template_bundle
from scripts.project_template_registry import load_registry, resolve_template


@dataclass(frozen=True)
class PreparedProjectCreation:
    """Validated inputs and the exact local template payload for later execution."""

    spec: ProjectSpec
    template: Template
    bundle: TemplateBundle
    plan: CreationPlan


def prepare_project_creation(
    raw_spec: Mapping[str, Any],
    *,
    registry_path: str | Path,
    repository_root: str | Path,
    provider_capabilities: set[str],
) -> PreparedProjectCreation:
    """Resolve and verify a project request without performing provider mutations.

    The returned bundle can be passed to create_project(..., template_bundle=...)
    so the same verified file payload is present in the adapter's CreationPlan.
    """
    spec = validate_project_spec(raw_spec)
    templates = load_registry(registry_path)
    template = resolve_template(templates, spec.template_id, spec.template_version)
    bundle = resolve_template_bundle(template, repository_root)
    plan = build_plan(spec, template, provider_capabilities, template_bundle=bundle)
    if not plan.template_files or set(plan.template_files) != set(plan.template_sha256):
        raise ProjectSpecError("prepared plan is missing verified template payload")
    return PreparedProjectCreation(spec=spec, template=template, bundle=bundle, plan=plan)
