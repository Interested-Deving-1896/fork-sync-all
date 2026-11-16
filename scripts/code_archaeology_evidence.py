#!/usr/bin/env python3
"""Collect bounded, read-only exact-blob evidence from two local Git repositories."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

SCHEMA_VERSION = 1
MAX_TREE_ENTRIES = 10000
MAX_TREE_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_OBSERVATIONS = 200


class CollectionError(RuntimeError):
    pass


def git(repo, *args):
    """Run a bounded Git read with caller GIT_* overrides and hooks disabled."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_PAGER": "cat",
        "PAGER": "cat",
    })
    command = [
        "git", "-C", str(repo), "--no-pager",
        "-c", "core.hooksPath=" + os.devnull,
        "-c", "core.fsmonitor=false",
        "-c", "core.pager=cat",
        *args,
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, timeout=30, env=env, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CollectionError(f"Git read operation failed: {type(exc).__name__}: {exc}") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).decode("utf-8", "replace").strip()
        raise CollectionError(f"git {args[0]} failed ({result.returncode}): {detail}")
    if len(result.stdout) > MAX_TREE_OUTPUT_BYTES:
        raise CollectionError("Git tree output exceeded the 16 MiB safety bound")
    return result.stdout


def resolve_commit(repo, revision):
    if not revision or revision.startswith("-"):
        raise ValueError("revision must be a non-empty Git revision")
    raw = git(repo, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}")
    return raw.decode("ascii").strip()


def read_tree(repo, revision, limit):
    commit = resolve_commit(repo, revision)
    raw = git(repo, "ls-tree", "-r", "-z", "--full-tree", commit)
    entries = {}
    scanned = 0
    truncated = False
    for record in raw.split(b"\0"):
        if not record:
            continue
        if scanned >= limit:
            truncated = True
            break
        metadata, separator, path = record.partition(b"\t")
        if not separator:
            raise CollectionError("Git returned an unparseable tree entry")
        fields = metadata.decode("ascii").split(" ", 2)
        if len(fields) != 3:
            raise CollectionError("Git returned incomplete tree metadata")
        mode, kind, object_id = fields
        scanned += 1
        # Only regular file blobs are compared. Symlinks, submodules and trees
        # are deliberately excluded from this first evidence contract.
        if kind == "blob" and mode in {"100644", "100755"}:
            entries.setdefault(object_id, []).append(path.decode("utf-8", "surrogateescape"))
    shallow = git(repo, "rev-parse", "--is-shallow-repository").decode("ascii").strip() == "true"
    return commit, entries, scanned, truncated, shallow


def collect_local_evidence(source_repo, target_repo, source_name, target_name,
                           source_revision="HEAD", target_revision="HEAD",
                           limit=MAX_TREE_ENTRIES):
    """Compare two local snapshots; exact blob overlap is only a low-confidence clue."""
    if not 1 <= limit <= MAX_TREE_ENTRIES:
        raise ValueError(f"limit must be between 1 and {MAX_TREE_ENTRIES}")
    source_path = Path(source_repo).expanduser().resolve(strict=True)
    target_path = Path(target_repo).expanduser().resolve(strict=True)
    source_commit, source_entries, source_count, source_truncated, source_shallow = read_tree(
        source_path, source_revision, limit)
    target_commit, target_entries, target_count, target_truncated, target_shallow = read_tree(
        target_path, target_revision, limit)
    complete = not (source_truncated or target_truncated)
    shallow = source_shallow or target_shallow
    shared = sorted(set(source_entries).intersection(target_entries))
    observations = []
    for object_id in shared[:MAX_OBSERVATIONS]:
        observations.append({
            "observation_id": "blob-" + object_id,
            "source_repository": source_name,
            "target_repository": target_name,
            "source_revision": source_commit,
            "target_revision": target_commit,
            "relationship": "unknown",
            "evidence_kind": "exact-blob-content-match",
            "locator": "git-blob:" + object_id,
            "blob_oid": object_id,
            "source_paths": sorted(source_entries[object_id]),
            "target_paths": sorted(target_entries[object_id]),
            "confidence": "low",
            "rationale": (
                "The selected snapshots contain the same Git blob object. Exact content "
                "identity is a candidate overlap only; it does not establish direction, "
                "historical origin, authorship, intent, or license compatibility."
            ),
            "alternatives": [
                "shared boilerplate or generated content",
                "vendored or copied content from another source",
                "independently introduced identical content",
            ],
            "coverage": {
                "complete": complete and len(shared) <= MAX_OBSERVATIONS,
                "pagination_complete": True,
                "shallow_or_missing_objects": shallow,
                "permission_gaps": [],
                "source_tree_entries_scanned": source_count,
                "target_tree_entries_scanned": target_count,
            },
            "license_review": "not-assessed",
        })
    if len(shared) > MAX_OBSERVATIONS:
        complete = False
    package_seed = "\n".join((source_name, source_commit, target_name, target_commit))
    package_id = hashlib.sha256(package_seed.encode("utf-8")).hexdigest()[:24]
    return {
        "schema_version": SCHEMA_VERSION,
        "contract": "fork-sync-all.origins-archaeology",
        "package_id": "local-git-" + package_id,
        "collector": {"name": "fork-sync-all-local-blob-evidence", "version": "0.1.0",
                      "provider": "local-git"},
        "collection_summary": {
            "source_repository": source_name,
            "target_repository": target_name,
            "source_revision": source_commit,
            "target_revision": target_commit,
            "source_tree_entries_scanned": source_count,
            "target_tree_entries_scanned": target_count,
            "shared_blob_count": len(shared),
            "observations_emitted": len(observations),
            "complete": complete,
            "shallow_or_missing_objects": shallow,
            "scope": "regular-file blob identity in two selected commit trees; no history traversal",
        },
        "observations": observations,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-repo", required=True, help="path to a local source Git repository")
    parser.add_argument("--target-repo", required=True, help="path to a local target Git repository")
    parser.add_argument("--source-name", required=True, help="stable source repository identifier")
    parser.add_argument("--target-name", required=True, help="stable target repository identifier")
    parser.add_argument("--source-revision", default="HEAD")
    parser.add_argument("--target-revision", default="HEAD")
    parser.add_argument("--limit", type=int, default=MAX_TREE_ENTRIES,
                        help="maximum tree entries scanned per repository (1..10000)")
    args = parser.parse_args(argv)
    try:
        package = collect_local_evidence(
            args.source_repo, args.target_repo, args.source_name, args.target_name,
            args.source_revision, args.target_revision, args.limit)
    except (CollectionError, OSError, ValueError) as exc:
        print(f"code-archaeology-evidence: {exc}", file=sys.stderr)
        return 2
    json.dump(package, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
