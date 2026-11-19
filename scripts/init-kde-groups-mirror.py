#!/usr/bin/env python3
"""
One-shot initialiser: creates all missing GitLab projects under kde-groups
and pushes branches+tags from invent.kde.org.

Designed to run as a GitLab CI job (no timeout issues, runs on GitLab infra).
Safe to re-run — skips projects that already exist and have commits.

Required env vars:
  GITLAB_TOKEN  — PAT with api + write_repository scope
  CI_API_V4_URL — set automatically by GitLab CI
"""
import os, sys, json, urllib.request, urllib.error, time, subprocess, tempfile, shutil

GL_TOKEN = os.environ["GITLAB_TOKEN"]
GL_API   = os.environ.get("CI_API_V4_URL", "https://gitlab.com/api/v4")
KDE_API  = "https://invent.kde.org/api/v4"
KDE_BASE = "https://invent.kde.org"

KDE_GROUPS_GL_ID   = "130743027"
KDE_GROUPS_GL_PATH = "openos-project/kde-ecosystem-deving/kde-groups"

# Group mapping file (committed alongside this script)
MAPPING_FILE = os.path.join(os.path.dirname(__file__), "kde-path-to-gl-id.json")

def gl(method, path, data=None):
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        f"{GL_API}{path}", data=body, method=method,
        headers={"PRIVATE-TOKEN": GL_TOKEN, "Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r), r.status
    except urllib.error.HTTPError as e:
        try: return json.loads(e.read().decode()), e.code
        except: return {}, e.code

def kde_paged(path):
    results, page = [], 1
    while True:
        req = urllib.request.Request(
            f"{KDE_API}{path}{'&' if '?' in path else '?'}per_page=100&page={page}",
            headers={"User-Agent": "openos-mirror/1.0"}
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                batch = json.load(r)
        except Exception as e:
            print(f"  KDE API error on {path}: {e}", flush=True)
            break
        if not batch:
            break
        results.extend(batch)
        page += 1
    return results

def push_mirror(kde_url, gl_url):
    work = tempfile.mkdtemp(prefix="kde-")
    try:
        r = subprocess.run(["git", "clone", "--mirror", kde_url, work],
                           capture_output=True, text=True, timeout=180)
        if r.returncode != 0:
            return False, f"clone: {r.stderr[-150:]}"
        gl_auth = gl_url.replace("https://", f"https://oauth2:{GL_TOKEN}@")
        r2 = subprocess.run(
            ["git", "-C", work, "push", gl_auth,
             "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"],
            capture_output=True, text=True, timeout=180
        )
        if r2.returncode != 0 and "Everything up-to-date" not in r2.stderr:
            return False, f"push: {r2.stderr[-150:]}"
        return True, ""
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)
    finally:
        shutil.rmtree(work, ignore_errors=True)

# Load group mapping
if os.path.exists(MAPPING_FILE):
    with open(MAPPING_FILE) as f:
        kde_path_to_gl_id = json.load(f)
else:
    print("ERROR: kde-path-to-gl-id.json not found. Run 01-create-groups.py first.", flush=True)
    sys.exit(1)

# Fetch all KDE groups
print("Fetching KDE groups...", flush=True)
kde_groups = kde_paged("/groups?all_available=true")
print(f"  {len(kde_groups)} groups", flush=True)

created = pushed = skipped = failed = 0

for group in sorted(kde_groups, key=lambda g: g["full_path"]):
    kde_group_path = group["full_path"]
    gl_parent_id   = kde_path_to_gl_id.get(kde_group_path)
    if not gl_parent_id:
        print(f"  ⚠️  No GL group for {kde_group_path}", flush=True)
        continue

    projects = kde_paged(f"/groups/{group['id']}/projects?include_subgroups=false")
    if not projects:
        continue

    print(f"\n[{kde_group_path}] {len(projects)} projects", flush=True)

    for p in projects:
        kde_proj_path = p["path_with_namespace"]
        name  = p["name"]
        slug  = p["path"]
        desc  = (p.get("description") or "").strip() or f"KDE mirror — {KDE_BASE}/{kde_proj_path}"
        branch = p.get("default_branch") or "master"

        # Create project if missing
        result, status = gl("POST", "/projects", {
            "name": name, "path": slug,
            "namespace_id": gl_parent_id,
            "description": desc[:255],
            "visibility": "public",
            "initialize_with_readme": False,
        })

        if status in (200, 201):
            gl_url = result["http_url_to_repo"]
            gl_id  = result["id"]
            created += 1
        elif status == 400 and ("taken" in str(result) or "exists" in str(result)):
            gl_full = f"{KDE_GROUPS_GL_PATH}/{kde_proj_path}"
            existing, s2 = gl("GET", f"/projects/{gl_full.replace('/', '%2F')}")
            if s2 == 200:
                gl_url = existing["http_url_to_repo"]
                gl_id  = existing["id"]
                # Check if already has commits — skip push if so
                commits, sc = gl("GET", f"/projects/{gl_id}/repository/commits?per_page=1")
                if sc == 200 and commits:
                    skipped += 1
                    continue
            else:
                print(f"    ⚠️  {kde_proj_path} exists but can't fetch", flush=True)
                failed += 1
                continue
        else:
            print(f"    ⚠️  {kde_proj_path} create HTTP {status}: {str(result)[:80]}", flush=True)
            failed += 1
            time.sleep(0.3)
            continue

        # Push
        ok, err = push_mirror(p["http_url_to_repo"], gl_url)
        if ok:
            gl("PUT", f"/projects/{gl_id}", {"default_branch": branch})
            print(f"    ✅ {kde_proj_path}", flush=True)
            pushed += 1
        else:
            print(f"    ⚠️  {kde_proj_path} push failed: {err[:80]}", flush=True)
            failed += 1

        time.sleep(0.1)

print(f"\n{'='*60}", flush=True)
print(f"Done — created={created} | pushed={pushed} | skipped={skipped} | failed={failed}", flush=True)
if failed > 0:
    sys.exit(1)
