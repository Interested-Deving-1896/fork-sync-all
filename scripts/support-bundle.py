#!/usr/bin/env python3
"""Create, inspect, and send sanitized Fork-Sync-All support bundles."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config/support-bundle.yml"
TOOL_VERSION = "1.0"
BUNDLE_ID_PATTERN = re.compile(r"^fsa-support-[A-Za-z0-9TZ-]+$")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Do not forward authentication headers across HTTP redirects."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        config = yaml.safe_load(stream) or {}
    if not isinstance(config.get("profiles"), dict):
        raise ValueError("support-bundle config must define profiles")
    return config


class Redactor:
    def __init__(self, config: dict, environ: dict[str, str]) -> None:
        redaction = config.get("redaction", {}) or {}
        self.secret_name = re.compile(redaction.get("secret_name_regex", r"(?i)(token|secret|password)"))
        self.patterns: list[tuple[str, re.Pattern[str], str]] = []
        self.counts: dict[str, int] = {}
        for item in redaction.get("patterns", []) or []:
            name = str(item["name"])
            self.patterns.append((name, re.compile(str(item["regex"])), str(item.get("replacement", "[REDACTED]"))))
            self.counts[name] = 0

        self.values: list[str] = []
        for name, value in environ.items():
            if self.secret_name.search(name) and len(value) >= 6:
                self.values.append(value)
        self.values.sort(key=len, reverse=True)
        self.counts["environment-secret-values"] = 0

    def text(self, value: str) -> str:
        result = value
        for secret in self.values:
            occurrences = result.count(secret)
            if occurrences:
                result = result.replace(secret, "[REDACTED]")
                self.counts["environment-secret-values"] += occurrences
        for name, pattern, replacement in self.patterns:
            result, count = pattern.subn(replacement, result)
            self.counts[name] += count
        return result

    def structured(self, value):
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.structured(item) for item in value]
        if isinstance(value, dict):
            return {str(key): self.structured(item) for key, item in value.items()}
        return value

    def report(self) -> dict:
        return {
            "redacted": sum(self.counts.values()),
            "counts": dict(sorted(self.counts.items())),
            "secret_environment_values_registered": len(self.values),
        }


class BundleBuilder:
    def __init__(self, config: dict, profile_name: str, include_remote: bool) -> None:
        if profile_name not in config["profiles"]:
            raise ValueError(f"unknown profile: {profile_name}")
        self.config = config
        self.profile_name = profile_name
        self.profile = config["profiles"][profile_name] or {}
        self.include_remote = include_remote
        self.redactor = Redactor(config, dict(os.environ))
        self.bundle_id = f"fsa-support-{dt.datetime.now(dt.timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}"
        self.command_timeout = int(config.get("defaults", {}).get("command_timeout_seconds", 90))
        self.max_file_bytes = int(config.get("defaults", {}).get("max_file_bytes", 2 * 1024 * 1024))
        self.warnings: list[str] = []

    @staticmethod
    def safe_env() -> dict[str, str]:
        allowed = ("PATH", "HOME", "LANG", "LC_ALL", "TERM", "CI")
        return {name: os.environ[name] for name in allowed if name in os.environ}

    def command(self, argv: list[str], timeout: int | None = None) -> dict:
        try:
            result = subprocess.run(
                argv,
                cwd=ROOT,
                env=self.safe_env(),
                capture_output=True,
                text=True,
                timeout=timeout or self.command_timeout,
                check=False,
            )
            return {
                "argv": argv,
                "exit_code": result.returncode,
                "stdout": result.stdout[-20000:],
                "stderr": result.stderr[-20000:],
            }
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"argv": argv, "exit_code": None, "error": str(exc)}

    def collect_metadata(self) -> dict:
        return {
            "bundle_id": self.bundle_id,
            "schema_version": int(self.config.get("schema_version", 1)),
            "tool_version": TOOL_VERSION,
            "created_at": utc_now(),
            "profile": self.profile_name,
            "profile_description": self.profile.get("description", ""),
            "include_remote": self.include_remote,
            "repository_name": ROOT.name,
        }

    def collect_system(self) -> dict:
        os_release: dict[str, str] = {}
        release_path = Path("/etc/os-release")
        if release_path.is_file():
            for line in release_path.read_text(errors="replace").splitlines():
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key in {"ID", "VERSION_ID", "NAME", "PRETTY_NAME"}:
                    os_release[key.lower()] = value.strip().strip('"')
        usage = shutil.disk_usage(ROOT)
        versions = {}
        for name, argv in {
            "git": ["git", "--version"],
            "python": [sys.executable, "--version"],
            "bash": ["bash", "--version"],
            "gh": ["gh", "--version"],
            "glab": ["glab", "--version"],
            "docker": ["docker", "--version"],
            "btrfs": ["btrfs", "version"],
            "mkdwarfs": ["mkdwarfs", "--version"],
        }.items():
            result = self.command(argv, timeout=10)
            versions[name] = {
                "available": result.get("exit_code") == 0,
                "version": (result.get("stdout") or result.get("stderr") or "").splitlines()[:1],
            }
        return {
            "os": os_release,
            "kernel": platform.release(),
            "architecture": platform.machine(),
            "python": platform.python_version(),
            "cpu_count": os.cpu_count(),
            "workspace_disk": {"total": usage.total, "used": usage.used, "free": usage.free},
            "versions": versions,
        }

    def collect_repository(self) -> dict:
        def git(*args: str) -> str:
            result = subprocess.run(
                ["git", *args], cwd=ROOT, capture_output=True, text=True, check=False, env=self.safe_env()
            )
            return result.stdout.strip()

        porcelain = git("status", "--porcelain=v1").splitlines()
        changes = {"staged": 0, "unstaged": 0, "untracked": 0, "conflicted": 0}
        for line in porcelain:
            code = line[:2]
            if code == "??":
                changes["untracked"] += 1
            else:
                changes["staged"] += int(code[0] not in {" ", "?"})
                changes["unstaged"] += int(code[1] not in {" ", "?"})
                changes["conflicted"] += int(code in {"DD", "AU", "UD", "UA", "DU", "AA", "UU"})

        checksums = {}
        for relative in self.config.get("repository_checksums", []) or []:
            path = ROOT / str(relative)
            checksums[str(relative)] = sha256_file(path) if path.is_file() else None

        commits = []
        raw = git("log", "-10", "--format=%H|%cI")
        for line in raw.splitlines():
            sha, _, committed_at = line.partition("|")
            commits.append({"sha": sha, "committed_at": committed_at})

        return {
            "branch": git("branch", "--show-current"),
            "head": git("rev-parse", "HEAD"),
            "is_shallow": git("rev-parse", "--is-shallow-repository") == "true",
            "tracked_files": int(git("ls-files", "-z").count("\0")),
            "dirty": bool(porcelain),
            "change_counts": changes,
            "recent_commits": commits,
            "configuration_checksums": checksums,
        }

    def collect_ci_context(self) -> dict:
        allowlist = self.config.get("ci_environment_allowlist", []) or []
        values = {name: os.environ[name] for name in allowlist if name in os.environ}
        present_secret_names = sorted(
            name for name, value in os.environ.items() if value and self.redactor.secret_name.search(name)
        )
        return {
            "values": values,
            "secret_variables_present": present_secret_names,
            "secret_values_included": False,
        }

    def collect_validation(self) -> dict:
        checks = []
        for item in self.config.get("validation_commands", []) or []:
            result = self.command([str(part) for part in item.get("argv", [])])
            result["name"] = str(item.get("name", "unnamed"))
            checks.append(result)
        return {
            "checks": checks,
            "passed": sum(check.get("exit_code") == 0 for check in checks),
            "failed": sum(check.get("exit_code") not in {0, None} for check in checks),
            "unavailable": sum(check.get("exit_code") is None for check in checks),
        }

    def collect_workflow_inventory(self) -> dict:
        github = sorted(path.name for path in (ROOT / ".github/workflows").glob("*.y*ml"))
        scripts = sorted(path.name for path in (ROOT / "scripts").glob("*.*") if path.is_file())
        adapters = sorted(
            str(path.relative_to(ROOT)) for path in (ROOT / "fsa-api/core/adapters").glob("**/*.sh")
        )
        return {
            "github_workflows": {"count": len(github), "names": github},
            "gitlab_ci_present": (ROOT / ".gitlab-ci.yml").is_file(),
            "scripts": {"count": len(scripts), "names": scripts},
            "fsa_api_adapters": {"count": len(adapters), "names": adapters},
        }

    def _remote_request(self, url: str, headers: dict[str, str]) -> object:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            raise ValueError("remote metadata endpoint must be an HTTPS URL without embedded credentials")
        request = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(NoRedirect)
        with opener.open(request, timeout=20) as response:
            return json.loads(response.read())

    def collect_remote_metadata(self) -> dict:
        context = {
            "requested": self.include_remote,
            "platform": os.environ.get("FSA_PLATFORM", "github" if os.environ.get("GITHUB_REPOSITORY") else "unknown"),
            "available": False,
            "runs": [],
        }
        if not self.include_remote:
            return context
        limit = int(self.config.get("defaults", {}).get("remote_run_limit", 20))
        try:
            platform_name = context["platform"]
            if platform_name == "github":
                token = os.environ.get("GH_TOKEN") or os.environ.get("SYNC_TOKEN") or os.environ.get("GITHUB_TOKEN")
                repo = os.environ.get("GITHUB_REPOSITORY") or os.environ.get("FSA_REPO")
                if not token or not repo:
                    raise ValueError("GitHub token or repository context is unavailable")
                data = self._remote_request(
                    f"https://api.github.com/repos/{repo}/actions/runs?per_page={limit}",
                    {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
                )
                context["runs"] = [
                    {
                        "id": run.get("id"),
                        "name": run.get("name"),
                        "event": run.get("event"),
                        "status": run.get("status"),
                        "conclusion": run.get("conclusion"),
                        "created_at": run.get("created_at"),
                        "updated_at": run.get("updated_at"),
                        "url": run.get("html_url"),
                    }
                    for run in data.get("workflow_runs", [])
                ]
            elif platform_name == "gitlab":
                token = os.environ.get("GITLAB_TOKEN")
                project = os.environ.get("CI_PROJECT_ID") or os.environ.get("CI_PROJECT_PATH")
                host = os.environ.get("CI_SERVER_URL", "https://gitlab.com")
                if not token or not project:
                    raise ValueError("GitLab token or project context is unavailable")
                encoded = urllib.parse.quote(project, safe="")
                data = self._remote_request(
                    f"{host}/api/v4/projects/{encoded}/pipelines?per_page={limit}",
                    {"PRIVATE-TOKEN": token, "Accept": "application/json"},
                )
                context["runs"] = [
                    {
                        "id": run.get("id"),
                        "status": run.get("status"),
                        "ref": run.get("ref"),
                        "created_at": run.get("created_at"),
                        "updated_at": run.get("updated_at"),
                        "url": run.get("web_url"),
                    }
                    for run in data
                ]
            else:
                raise ValueError(f"remote metadata adapter is not configured for {platform_name}")
            context["available"] = True
        except Exception as exc:  # Degrade; support-bundle creation must still succeed.
            context["error"] = str(exc)
            self.warnings.append(f"remote metadata unavailable: {exc}")
        return context

    def collect_logs(self, stage: Path) -> dict:
        candidates: list[Path] = []
        for pattern in self.config.get("log_paths", []) or []:
            for value in glob.glob(str(ROOT / str(pattern)), recursive=True):
                path = Path(value)
                if path.is_file() and path.resolve().is_relative_to(ROOT.resolve()):
                    candidates.append(path)
        copied = []
        for index, path in enumerate(sorted(set(candidates))):
            size = path.stat().st_size
            with path.open("rb") as stream:
                if size > self.max_file_bytes:
                    stream.seek(-self.max_file_bytes, os.SEEK_END)
                raw = stream.read(self.max_file_bytes)
            text = raw.decode("utf-8", errors="replace")
            relative = path.relative_to(ROOT)
            target_name = f"logs/{index:03d}-{relative.name}"
            self.write_text(stage / target_name, text)
            copied.append({"source": str(relative), "bundle_path": target_name, "source_size": size})
        return {"files": copied, "count": len(copied), "truncated_at_bytes": self.max_file_bytes}

    def write_json(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        safe = self.redactor.structured(value)
        path.write_text(json.dumps(safe, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def write_text(self, path: Path, value: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.redactor.text(value), encoding="utf-8")

    def build(self, output_dir: Path) -> dict:
        collectors = [str(name) for name in self.profile.get("collectors", [])]
        mapping = {
            "metadata": self.collect_metadata,
            "system": self.collect_system,
            "repository": self.collect_repository,
            "ci_context": self.collect_ci_context,
            "validation": self.collect_validation,
            "workflow_inventory": self.collect_workflow_inventory,
            "remote_metadata": self.collect_remote_metadata,
        }

        output_dir.mkdir(parents=True, exist_ok=True)
        archive = output_dir / f"{self.bundle_id}.zip"
        with tempfile.TemporaryDirectory(prefix="fsa-support-") as temporary:
            stage = Path(temporary) / self.bundle_id
            stage.mkdir()
            for collector in collectors:
                if collector == "logs":
                    result = self.collect_logs(stage)
                elif collector in mapping:
                    result = mapping[collector]()
                else:
                    self.warnings.append(f"unknown collector skipped: {collector}")
                    continue
                self.write_json(stage / f"{collector}.json", result)

            self.write_json(stage / "redaction-report.json", self.redactor.report())
            files = []
            for path in sorted(stage.rglob("*")):
                if path.is_file():
                    files.append(
                        {
                            "path": str(path.relative_to(stage)),
                            "size": path.stat().st_size,
                            "sha256": sha256_file(path),
                        }
                    )
            manifest = {
                "bundle_id": self.bundle_id,
                "schema_version": int(self.config.get("schema_version", 1)),
                "tool_version": TOOL_VERSION,
                "created_at": utc_now(),
                "profile": self.profile_name,
                "collectors": collectors,
                "warnings": self.redactor.structured(self.warnings),
                "files": files,
                "redaction": self.redactor.report(),
            }
            self.write_json(stage / "manifest.json", manifest)

            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
                for path in sorted(stage.rglob("*")):
                    if path.is_file():
                        bundle.write(path, arcname=f"{self.bundle_id}/{path.relative_to(stage)}")

        max_bytes = int(self.config.get("defaults", {}).get("max_bundle_bytes", 50 * 1024 * 1024))
        if archive.stat().st_size > max_bytes:
            archive.unlink(missing_ok=True)
            raise ValueError(f"bundle exceeds maximum size of {max_bytes} bytes")
        digest = sha256_file(archive)
        sidecar = archive.with_suffix(archive.suffix + ".sha256")
        sidecar.write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
        return {
            "ok": True,
            "bundle_id": self.bundle_id,
            "profile": self.profile_name,
            "path": str(archive.resolve()),
            "sha256_path": str(sidecar.resolve()),
            "sha256": digest,
            "size": archive.stat().st_size,
            "warnings": self.redactor.structured(self.warnings),
        }


def inspect_bundle(path: Path, config: dict | None = None) -> dict:
    if not path.is_file():
        raise ValueError(f"bundle not found: {path}")
    defaults = (config or {}).get("defaults", {}) or {}
    max_archive = int(defaults.get("max_bundle_bytes", 50 * 1024 * 1024))
    max_entries = int(defaults.get("max_archive_entries", 256))
    max_uncompressed = int(defaults.get("max_uncompressed_bytes", 100 * 1024 * 1024))
    max_ratio = int(defaults.get("max_compression_ratio", 200))
    if path.stat().st_size > max_archive:
        raise ValueError(f"archive exceeds maximum size of {max_archive} bytes")
    with zipfile.ZipFile(path) as bundle:
        infos = bundle.infolist()
        if len(infos) > max_entries:
            raise ValueError(f"archive exceeds maximum entry count of {max_entries}")
        uncompressed = sum(info.file_size for info in infos)
        if uncompressed > max_uncompressed:
            raise ValueError(f"archive exceeds maximum uncompressed size of {max_uncompressed} bytes")
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ValueError("archive contains duplicate entry names")
        for info in infos:
            mode = (info.external_attr >> 16) & 0o170000
            if info.is_dir() or mode == stat.S_IFLNK:
                raise ValueError(f"archive contains unsupported entry type: {info.filename}")
            if info.file_size > 1024 * 1024 and info.compress_size > 0:
                if info.file_size / info.compress_size > max_ratio:
                    raise ValueError(f"suspicious compression ratio for {info.filename}")
        for name in names:
            pure = PurePosixPath(name)
            if pure.is_absolute() or ".." in pure.parts:
                raise ValueError(f"unsafe archive path: {name}")
        manifest_names = [name for name in names if name.endswith("/manifest.json")]
        if len(manifest_names) != 1:
            raise ValueError("bundle must contain exactly one manifest.json")
        manifest = json.loads(bundle.read(manifest_names[0]))
        prefix = manifest_names[0].removesuffix("manifest.json")
        bundle_id = manifest.get("bundle_id")
        if not isinstance(bundle_id, str) or not BUNDLE_ID_PATTERN.fullmatch(bundle_id):
            raise ValueError("manifest contains an invalid bundle_id")
        if prefix != f"{bundle_id}/":
            raise ValueError("archive root does not match manifest bundle_id")
        entries = manifest.get("files")
        if not isinstance(entries, list):
            raise ValueError("manifest files must be a list")
        errors = []
        listed_names = set()
        verified_files = 0
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                raise ValueError("manifest contains an invalid file entry")
            relative = PurePosixPath(entry["path"])
            if relative.is_absolute() or ".." in relative.parts or str(relative) in {"", "."}:
                raise ValueError(f"manifest contains an unsafe file path: {entry['path']}")
            name = prefix + str(relative)
            if name in listed_names:
                raise ValueError(f"manifest lists a file more than once: {entry['path']}")
            listed_names.add(name)
            try:
                data = bundle.read(name)
            except KeyError:
                errors.append(f"missing: {entry['path']}")
                continue
            digest = hashlib.sha256(data).hexdigest()
            if digest != entry.get("sha256"):
                errors.append(f"checksum mismatch: {entry['path']}")
            if len(data) != entry.get("size"):
                errors.append(f"size mismatch: {entry['path']}")
            if digest == entry.get("sha256") and len(data) == entry.get("size"):
                verified_files += 1
        expected_names = listed_names | {manifest_names[0]}
        for extra in sorted(set(names) - expected_names):
            errors.append(f"unlisted archive entry: {extra}")
        for missing in sorted(expected_names - set(names)):
            errors.append(f"missing archive entry: {missing}")
    return {
        "ok": not errors,
        "path": str(path.resolve()),
        "archive_sha256": sha256_file(path),
        "archive_size": path.stat().st_size,
        "bundle_id": bundle_id,
        "profile": manifest.get("profile"),
        "created_at": manifest.get("created_at"),
        "collectors": manifest.get("collectors", []),
        "redaction": manifest.get("redaction", {}),
        "warnings": manifest.get("warnings", []),
        "verified_files": verified_files,
        "errors": errors,
    }


def send_bundle(path: Path, transport: str, destination: str, method: str, force: bool, config: dict) -> dict:
    inspection = inspect_bundle(path, config)
    if not inspection["ok"]:
        raise ValueError("refusing to send an invalid bundle")
    allowed = config.get("send", {}).get("allowed_transports", ["local", "http"])
    if transport not in allowed:
        raise ValueError(f"transport is not allowed by policy: {transport}")

    if transport == "local":
        target = Path(destination).expanduser()
        if target.exists() and target.is_dir():
            target = target / path.name
        elif destination.endswith(os.sep):
            target.mkdir(parents=True, exist_ok=True)
            target = target / path.name
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and not force:
            raise ValueError(f"destination exists (use --force): {target}")
        shutil.copy2(path, target)
        sidecar = path.with_suffix(path.suffix + ".sha256")
        if sidecar.is_file():
            shutil.copy2(sidecar, target.with_suffix(target.suffix + ".sha256"))
        return {"ok": True, "transport": transport, "destination": str(target.resolve()), **inspection}

    parsed = urllib.parse.urlparse(destination)
    allowed_schemes = config.get("send", {}).get("allowed_http_schemes", ["https"])
    if parsed.scheme not in allowed_schemes or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError(f"destination must use an allowed absolute URL scheme: {allowed_schemes}")
    token_env = str(config.get("send", {}).get("upload_token_env", "FSA_SUPPORT_UPLOAD_TOKEN"))
    headers = {
        "Content-Type": "application/zip",
        "User-Agent": f"fork-sync-all-support-bundle/{TOOL_VERSION}",
        "X-FSA-Bundle-ID": str(inspection["bundle_id"]),
        "X-FSA-SHA256": str(inspection["archive_sha256"]),
    }
    if os.environ.get(token_env):
        headers["Authorization"] = f"Bearer {os.environ[token_env]}"
    request = urllib.request.Request(destination, data=path.read_bytes(), headers=headers, method=method)
    timeout = int(config.get("send", {}).get("timeout_seconds", 60))
    try:
        opener = urllib.request.build_opener(NoRedirect)
        with opener.open(request, timeout=timeout) as response:
            body = response.read(4096).decode("utf-8", errors="replace")
            return {
                "ok": True,
                "transport": transport,
                "destination": destination,
                "status": response.status,
                "response_excerpt": Redactor(config, dict(os.environ)).text(body),
                **inspection,
            }
    except urllib.error.HTTPError as exc:
        body = exc.read(4096).decode("utf-8", errors="replace")
        safe = Redactor(config, dict(os.environ)).text(body)
        raise ValueError(f"upload failed with HTTP {exc.code}: {safe}") from exc


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    commands = root.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create", help="create a sanitized support bundle")
    create.add_argument("--profile", choices=("minimal", "standard", "full"))
    create.add_argument("--output", type=Path)
    create.add_argument("--include-remote", action="store_true")

    inspect = commands.add_parser("inspect", help="inspect and verify a bundle")
    inspect.add_argument("bundle", type=Path)

    send = commands.add_parser("send", help="verify and send a bundle")
    send.add_argument("bundle", type=Path)
    send.add_argument("--transport", choices=("local", "http"), required=True)
    send.add_argument("--destination", required=True)
    send.add_argument("--method", choices=("PUT", "POST"), default="PUT")
    send.add_argument("--force", action="store_true")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        config = load_config(args.config)
        if args.command == "create":
            defaults = config.get("defaults", {}) or {}
            profile_name = args.profile or str(defaults.get("profile", "standard"))
            output = args.output or ROOT / str(defaults.get("output_dir", "artifacts/support-bundles"))
            result = BundleBuilder(config, profile_name, args.include_remote).build(output)
        elif args.command == "inspect":
            result = inspect_bundle(args.bundle, config)
        else:
            result = send_bundle(args.bundle, args.transport, args.destination, args.method, args.force, config)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("ok") else 1
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
