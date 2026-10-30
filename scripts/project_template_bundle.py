"""Resolve registry templates to verified, repository-local bundles only.

No network access, archive extraction, repository creation, or mirror propagation
is performed here. Bundle paths are fixed by the registry ID and exact version.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path, PurePosixPath
import re
from typing import Mapping

import yaml

from scripts.project_creation_engine import ProjectSpecError, Template
from scripts.project_template_registry import _UniqueKeySafeLoader


_REGISTRY_URI_RE = re.compile(
    r"^registry://([a-zA-Z0-9][a-zA-Z0-9._-]{0,99})/"
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_BUNDLE_SCHEMA_VERSION = "1.0"


@dataclass(frozen=True)
class TemplateBundle:
    """Validated bundle files keyed by safe, POSIX-relative paths."""

    template_id: str
    version: str
    source: str
    files: Mapping[str, str]
    sha256: Mapping[str, str]


def _reject_symlink(path: Path) -> None:
    if path.is_symlink():
        raise ProjectSpecError(f"template bundle must not contain symlinks: {path.name}")


def _contained_path(base: Path, relative: str) -> Path:
    """Validate a manifest path and ensure it remains within the bundle."""
    if not isinstance(relative, str) or not relative or any(
        ord(char) < 32 or ord(char) == 127 for char in relative
    ):
        raise ProjectSpecError("bundle file path must be a non-empty string without control characters")
    if "\\" in relative:
        raise ProjectSpecError("bundle file paths must use POSIX separators")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in relative.split("/")):
        raise ProjectSpecError(f"unsafe bundle file path: {relative!r}")
    if ":" in pure.parts[0]:
        raise ProjectSpecError(f"unsafe bundle file path: {relative!r}")
    target = base.joinpath(*pure.parts)
    try:
        target.resolve(strict=True).relative_to(base.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise ProjectSpecError(f"bundle file escapes its trusted directory or is missing: {relative!r}") from exc
    current = base
    for part in pure.parts:
        current = current / part
        _reject_symlink(current)
    if not target.is_file():
        raise ProjectSpecError(f"bundle entry is not a regular file: {relative!r}")
    return target


def resolve_template_bundle(template: Template, repository_root: str | Path) -> TemplateBundle:
    """Load a fixed-path local bundle and verify every manifest-listed file hash.

    Only registry://<template-id>/<exact-semver> is supported. Unknown schemes,
    mismatched URI identities, missing manifests, unsafe paths, duplicate
    manifest keys, symlinks, and checksum mismatches fail closed.
    """
    if not isinstance(template, Template):
        raise ProjectSpecError("template must be a validated Template")
    match = _REGISTRY_URI_RE.fullmatch(template.source)
    if not match:
        raise ProjectSpecError("only exact registry://<template-id>/<x.y.z> sources are supported")
    uri_id, major, minor, patch = match.groups()
    uri_version = f"{major}.{minor}.{patch}"
    if uri_id != template.template_id or uri_version != template.version:
        raise ProjectSpecError("registry source identity does not match template ID and version")

    root = Path(repository_root).absolute()
    if not root.exists() or not root.is_dir():
        raise ProjectSpecError("repository root must be an existing directory")
    _reject_symlink(root)
    bundle_dir = root / "templates" / "project-creation" / uri_id / uri_version
    current = root
    for part in ("templates", "project-creation", uri_id, uri_version):
        current = current / part
        if not current.exists() or not current.is_dir():
            raise ProjectSpecError("local template bundle was not found")
        _reject_symlink(current)
    try:
        bundle_dir.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise ProjectSpecError("template bundle is outside the repository root") from exc

    manifest_path = bundle_dir / "manifest.yml"
    _reject_symlink(manifest_path)
    try:
        raw = yaml.load(manifest_path.read_text(encoding="utf-8"), Loader=_UniqueKeySafeLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise ProjectSpecError("unable to read a valid local template manifest") from exc
    if not isinstance(raw, dict) or raw.get("schema_version") != _BUNDLE_SCHEMA_VERSION:
        raise ProjectSpecError("template manifest schema_version must be '1.0'")
    if raw.get("template_id") != template.template_id or raw.get("version") != template.version:
        raise ProjectSpecError("template manifest identity does not match registry entry")
    entries = raw.get("files")
    if not isinstance(entries, list) or not entries:
        raise ProjectSpecError("template manifest files must be a non-empty list")

    contents: dict[str, str] = {}
    hashes: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ProjectSpecError("each template manifest file entry must be a mapping")
        relative = entry.get("path")
        expected_hash = entry.get("sha256")
        if not isinstance(expected_hash, str) or not _SHA256_RE.fullmatch(expected_hash):
            raise ProjectSpecError("each template manifest file requires a lowercase SHA-256 checksum")
        if not isinstance(relative, str):
            raise ProjectSpecError("each template manifest file requires a string path")
        if relative in contents:
            raise ProjectSpecError(f"duplicate template manifest file: {relative!r}")
        target = _contained_path(bundle_dir, relative)
        try:
            data = target.read_bytes()
            content = data.decode("utf-8")
        except (OSError, UnicodeError) as exc:
            raise ProjectSpecError(f"template file must be readable UTF-8: {relative!r}") from exc
        actual_hash = hashlib.sha256(data).hexdigest()
        if actual_hash != expected_hash:
            raise ProjectSpecError(f"template file checksum mismatch: {relative!r}")
        contents[relative] = content
        hashes[relative] = actual_hash

    return TemplateBundle(
        template_id=template.template_id,
        version=template.version,
        source=template.source,
        files=contents,
        sha256=hashes,
    )
