#!/usr/bin/env python3
"""Read-only local-Git code archaeology for Fork-Sync-All; Python 3.10+."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

MAX_LIMIT = 200


class ArchaeologyError(RuntimeError):
    pass


def git(repo, *args):
    # Do not inherit repository/config redirection variables from the caller.
    # GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_CONFIG_* and related
    # variables can otherwise redirect or alter an apparently read-only query.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({"GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_PAGER": "cat", "PAGER": "cat"})
    command = ["git", "-C", str(repo), "--no-pager",
               "-c", "core.hooksPath=" + os.devnull,
               "-c", "core.fsmonitor=false", "-c", "diff.external=",
               "-c", "core.pager=cat", *args]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                encoding="utf-8", errors="replace",
                                timeout=30, env=env, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ArchaeologyError(f"Git read operation failed: {type(exc).__name__}: {exc}") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise ArchaeologyError(f"git {args[0]} failed ({result.returncode}): {detail}")
    return result.stdout


def safe_path(value):
    if value is None:
        return None
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("path must be repository-relative and must not contain '..'")
    return value


def commits(repo, revision, limit, path=None, pickaxe=None, regex=False):
    fmt = "%H%x1f%P%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%aI%x1f%cI%x1f%s"
    args = ["log", "--no-show-signature", f"--max-count={limit}", f"--format={fmt}"]
    if pickaxe is not None:
        args += ["-G" if regex else "-S", pickaxe]
    args.append(revision)
    if path:
        args += ["--", path]
    rows = []
    for line in git(repo, *args).splitlines():
        fields = line.split("\x1f", 8)
        if len(fields) != 9:
            continue
        sha, parents, author, author_email, committer, committer_email, authored, committed, subject = fields
        rows.append({"sha": sha, "parents": parents.split() if parents else [],
                     "author_name": author, "author_email": author_email,
                     "committer_name": committer, "committer_email": committer_email,
                     "authored_at": authored, "committed_at": committed, "subject": subject})
    return rows


def investigate(repo_arg=".", revision="HEAD", path=None, start=None, end=None,
                pickaxe=None, regex=False, limit=30):
    if not 1 <= limit <= MAX_LIMIT:
        raise ValueError(f"limit must be between 1 and {MAX_LIMIT}")
    path = safe_path(path)
    repo = Path(git(Path(repo_arg).expanduser().resolve(), "rev-parse", "--show-toplevel").strip())
    head = git(repo, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}").strip()
    shallow = git(repo, "rev-parse", "--is-shallow-repository").strip() == "true"
    recent = commits(repo, head, limit, path)
    matches = commits(repo, head, limit, path, pickaxe, regex) if pickaxe is not None else []
    blame = None
    if start is not None or end is not None:
        if not path:
            raise ValueError("blame line ranges require --path")
        first, last = start or 1, end or start or 1
        if first < 1 or last < first:
            raise ValueError("line range must satisfy 1 <= start <= end")
        blame = {"start_line": first, "end_line": last,
                 "porcelain": git(repo, "blame", "--line-porcelain",
                                  f"-L{first},{last}", head, "--", path)}
    refs = []
    for line in git(repo, "for-each-ref", "--format=%(refname)%09%(objectname)%09%(objecttype)",
                    "refs/heads", "refs/tags").splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            refs.append({"name": parts[0], "object_id": parts[1], "object_type": parts[2]})
    return {
        "schema_version": 1, "engine": "fork-sync-all-code-archaeology",
        "engine_version": "0.1.0", "repository": str(repo), "revision": revision,
        "resolved_commit": head,
        "history_completeness": "shallow_or_incomplete" if shallow else "local_object_database_only",
        "read_only": True,
        "execution_policy": {"repository_hooks_executed": False, "repository_code_executed": False,
                             "network_access": False, "worktree_or_ref_mutations": False},
        "scope": {"path": path, "line_start": start, "line_end": end,
                  "pickaxe": pickaxe, "pickaxe_mode": ("regex" if regex else "literal") if pickaxe is not None else None,
                  "max_commits": limit},
        "commits": recent, "pickaxe_matches": matches, "blame": blame, "refs": refs,
        "limitations": [
            "Local Git object database only; no provider PR/MR, review, issue, check, release or deployment evidence.",
            "A non-shallow repository may still have missing, filtered, grafted or replaced history.",
            "Git author and committer fields are commit metadata, not verified identities.",
            "Blame is an attribution clue, not proof of intent or current ownership.",
            "Rename following, moved/copied-line detection and cross-repository lineage are not implemented.",
        ],
    }


def render_markdown(report):
    lines = [f"# Code archaeology: {report['repository']}", "",
             f"- Revision: {report['revision']} → {report['resolved_commit']}",
             f"- History: {report['history_completeness']}",
             "- Read-only: yes; no repository hooks or repository code executed.", "",
             "## Recent commits", "", "| Commit | Author metadata | Date | Subject |",
             "|---|---|---|---|"]
    for row in report["commits"]:
        lines.append(f"| {row['sha'][:12]} | {row['author_name']} | {row['authored_at']} | {row['subject'].replace('|', chr(92) + '|')} |")
    if not report["commits"]:
        lines.append("| — | — | — | No commits returned. |")
    if report["pickaxe_matches"]:
        lines += ["", "## Pickaxe matches", ""]
        lines += [f"- {row['sha'][:12]} {row['subject']}" for row in report["pickaxe_matches"]]
    if report["blame"]:
        lines += ["", "## Blame evidence", "",
                  f"Raw line-porcelain evidence for lines {report['blame']['start_line']}–{report['blame']['end_line']} is in JSON."]
    lines += ["", "## Limitations", ""] + [f"- {item}" for item in report["limitations"]]
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--path")
    parser.add_argument("--start", type=int)
    parser.add_argument("--end", type=int)
    parser.add_argument("--pickaxe")
    parser.add_argument("--regex", action="store_true")
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)
    if (args.start is not None or args.end is not None) and not args.path:
        parser.error("--start/--end require --path")
    if args.regex and args.pickaxe is None:
        parser.error("--regex requires --pickaxe")
    try:
        report = investigate(args.repo, args.revision, args.path, args.start, args.end,
                             args.pickaxe, args.regex, args.limit)
    except (ArchaeologyError, ValueError) as exc:
        print(f"code-archaeology: {exc}", file=sys.stderr)
        return 2
    output = render_markdown(report) if args.format == "markdown" else json.dumps(report, indent=2, sort_keys=True)
    sys.stdout.write(output + ("" if output.endswith("\n") else "\n"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
