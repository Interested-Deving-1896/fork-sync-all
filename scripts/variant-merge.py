#!/usr/bin/env python3
"""
scripts/variant-merge.py

Syncs shared config files from fork-sync-all (GitHub) to
fork-sync-all-gitlab (GitLab), applying union merge for registry files
and GitHub-wins for prose files.

Direction: github-to-gitlab (default) or gitlab-to-github

Files synced:
  Union merge (both sides contribute, no deletions):
    config/ota-registry.yml
    config/ota-blocklist.yml
    registered-imports.json

  GitHub-wins (GitHub is authoritative):
    config/template-manifest.yml
    .ota/schema.yml
    CHANGELOG.md

Usage:
  python3 scripts/variant-merge.py \\
    --github-token  GH_TOKEN \\
    --gitlab-token  GITLAB_TOKEN \\
    --github-repo   Interested-Deving-1896/fork-sync-all \\
    --gitlab-project openos-project/fork-sync-all-gitlab \\
    --gitlab-url    https://gitlab.com \\
    [--direction    github-to-gitlab] \\
    [--dry-run]
"""

import argparse
import base64
import json
import sys
import urllib.request
import urllib.error


def gh_get(token, path):
    url = f"https://api.github.com/repos/{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def gl_get(token, gitlab_url, project_encoded, path):
    url = f"{gitlab_url}/api/v4/projects/{project_encoded}/repository/files/{path}?ref=main"
    req = urllib.request.Request(url, headers={"PRIVATE-TOKEN": token})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def gl_put(token, gitlab_url, project_encoded, path, content, message, existing_sha=None):
    url = f"{gitlab_url}/api/v4/projects/{project_encoded}/repository/files/{path}"
    payload = json.dumps({
        "branch": "main",
        "content": content,
        "commit_message": message,
        **({"last_commit_id": existing_sha} if existing_sha else {}),
    }).encode()
    method = "PUT" if existing_sha else "POST"
    req = urllib.request.Request(url, data=payload, method=method, headers={
        "PRIVATE-TOKEN": token,
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def union_merge_yaml_list(gh_content, gl_content):
    """
    Simple union merge for YAML list files: combine unique lines from both sides.
    Preserves comments and ordering from GitHub side, appends GitLab-only entries.
    """
    gh_lines = gh_content.splitlines()
    gl_lines = gl_content.splitlines() if gl_content else []

    # Extract non-comment, non-empty lines as a set for dedup
    gh_entries = {l.strip() for l in gh_lines if l.strip() and not l.strip().startswith('#')}
    gl_only = [l for l in gl_lines if l.strip() and not l.strip().startswith('#')
               and l.strip() not in gh_entries]

    if gl_only:
        return gh_content.rstrip() + "\n" + "\n".join(gl_only) + "\n"
    return gh_content


def main():
    parser = argparse.ArgumentParser(description="Sync fork-sync-all config to GitLab variant")
    parser.add_argument("--github-token",    required=True)
    parser.add_argument("--gitlab-token",    required=True)
    parser.add_argument("--github-repo",     required=True)
    parser.add_argument("--gitlab-project",  required=True)
    parser.add_argument("--gitlab-url",      default="https://gitlab.com")
    parser.add_argument("--direction",       default="github-to-gitlab",
                        choices=["github-to-gitlab", "gitlab-to-github"])
    parser.add_argument("--dry-run",         action="store_true")
    args = parser.parse_args()

    import urllib.parse
    project_encoded = urllib.parse.quote(args.gitlab_project, safe="")

    UNION_FILES = [
        "config/ota-registry.yml",
        "config/ota-blocklist.yml",
        "registered-imports.json",
    ]
    GH_WINS_FILES = [
        "config/template-manifest.yml",
        ".ota/schema.yml",
        "CHANGELOG.md",
    ]

    synced = 0
    skipped = 0
    errors = 0

    all_files = [(f, "union") for f in UNION_FILES] + [(f, "gh-wins") for f in GH_WINS_FILES]

    for filepath, strategy in all_files:
        print(f"  {filepath} [{strategy}]", flush=True)
        try:
            # Fetch from GitHub
            encoded_path = urllib.parse.quote(filepath, safe="")
            gh_data = gh_get(args.github_token, f"{args.github_repo}/contents/{filepath}")
            gh_content = base64.b64decode(gh_data["content"]).decode("utf-8")

            # Fetch from GitLab
            gl_data = gl_get(args.gitlab_token, args.gitlab_url, project_encoded, encoded_path)
            gl_content = base64.b64decode(gl_data["content"]).decode("utf-8") if gl_data else None
            gl_sha = gl_data.get("last_commit_id") if gl_data else None

            if strategy == "union" and gl_content:
                new_content = union_merge_yaml_list(gh_content, gl_content)
            else:
                new_content = gh_content

            if gl_content == new_content:
                print(f"    no change", flush=True)
                skipped += 1
                continue

            if args.dry_run:
                print(f"    [dry-run] would update", flush=True)
                synced += 1
                continue

            gl_put(
                args.gitlab_token, args.gitlab_url, project_encoded,
                encoded_path, new_content,
                f"chore(sync): update {filepath} from GitHub [skip ci]",
                gl_sha,
            )
            print(f"    updated", flush=True)
            synced += 1

        except Exception as e:
            print(f"    ERROR: {e}", file=sys.stderr, flush=True)
            errors += 1

    print(f"\nDone — synced: {synced} | skipped: {skipped} | errors: {errors}")
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
