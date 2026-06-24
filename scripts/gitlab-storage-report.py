#!/usr/bin/env python3
"""
Report storage for all projects listed in config/gitlab-subgroups.yml.
Fetches each project individually (token needs read access per project).
"""
import os, json, urllib.request, urllib.error

token = os.environ["GITLAB_TOKEN"]
api   = os.environ.get("GL_API",   "https://gitlab.com/api/v4")

# Read subgroups config
import sys
sys.path.insert(0, os.path.dirname(__file__))

config_path = os.path.join(os.path.dirname(__file__), "..", "config", "gitlab-subgroups.yml")

# Parse YAML manually (no PyYAML on runner by default — use simple line parser)
subgroups = {}
current_sg = None
current_path = None
in_repos = False

with open(config_path) as f:
    for line in f:
        stripped = line.rstrip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        content = stripped.strip()

        if indent == 2 and content.endswith(":") and not content.startswith("-"):
            current_sg = content[:-1]
            subgroups[current_sg] = {"path": None, "repos": []}
            in_repos = False
        elif indent == 4 and content.startswith("path:"):
            if current_sg:
                subgroups[current_sg]["path"] = content.split("path:", 1)[1].strip()
        elif indent == 4 and content == "repos:":
            in_repos = True
        elif indent == 6 and content.startswith("- ") and in_repos and current_sg:
            subgroups[current_sg]["repos"].append(content[2:].strip())
        elif indent == 4 and not content.startswith("-"):
            in_repos = False

def gl_get(path):
    req = urllib.request.Request(f"{api}{path}",
        headers={"PRIVATE-TOKEN": token, "User-Agent": "fork-sync-all"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"_error": e.code}

def fmt(b):
    if b >= 1073741824: return f"{b/1073741824:.1f}G"
    if b >= 1048576:    return f"{b/1048576:.1f}M"
    if b >= 1024:       return f"{b/1024:.1f}K"
    return f"{b}B"

results = []
for sg_name, sg in subgroups.items():
    gl_path = sg.get("path", "")
    for repo in sg.get("repos", []):
        encoded = (gl_path + "/" + repo).replace("/", "%2F")
        p = gl_get(f"/projects/{encoded}?statistics=true")
        if "_error" in p:
            print(f"  SKIP {gl_path}/{repo}: HTTP {p['_error']}", flush=True)
            continue
        s = p.get("statistics", {})
        repo_sz = s.get("repository_size", 0)
        lfs_sz  = s.get("lfs_objects_size", 0)
        art_sz  = s.get("job_artifacts_size", 0)
        total   = s.get("storage_size", 0)
        full_path = p.get("path_with_namespace", f"{gl_path}/{repo}")
        results.append((full_path, repo_sz, lfs_sz, art_sz, total))
        print(f"  {full_path}: repo={fmt(repo_sz)} lfs={fmt(lfs_sz)} art={fmt(art_sz)} total={fmt(total)}", flush=True)

results.sort(key=lambda x: x[1], reverse=True)

print()
hdr = f"{'Project':<70} {'Repo':>10} {'LFS':>10} {'Artifacts':>10} {'Total':>10}"
print(hdr)
print("=" * len(hdr))
total_repo = total_lfs = total_art = total_all = 0
for name, repo, lfs, art, total in results:
    n = name if len(name) <= 68 else name[:65] + "..."
    print(f"{n:<70} {fmt(repo):>10} {fmt(lfs):>10} {fmt(art):>10} {fmt(total):>10}")
    total_repo += repo; total_lfs += lfs; total_art += art; total_all += total
print("=" * len(hdr))
print(f"{'TOTAL':<70} {fmt(total_repo):>10} {fmt(total_lfs):>10} {fmt(total_art):>10} {fmt(total_all):>10}")

# Flag anything over 1 GiB repository storage
print("\nProjects over 1 GiB repository storage:")
over = [(n, r) for n, r, *_ in results if r >= 1073741824]
if over:
    for n, r in over:
        print(f"  {n}: {fmt(r)}")
else:
    print("  None")
