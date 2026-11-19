#!/usr/bin/env bash
#
# Manages git subtrees, submodules, and umbrella repo relationships
# declared in config/subtree-manifest.yml.
#
# Commands:
#   sync        — add/update all subtrees and submodules per manifest
#   add-subtree — add a single subtree (args: name remote branch prefix)
#   pull-subtree— pull latest from a subtree remote (args: name)
#   add-submodule — add a single submodule (args: name url path branch)
#   update-submodules — update all submodules to latest on their branch
#   umbrella-init — initialise umbrella repo (add all children as submodules)
#   status      — show current state of all subtrees and submodules
#
# Required env vars:
#   GH_TOKEN    — PAT (needed only for private repos)
#
# Optional env vars:
#   DRY_RUN     — true = log without executing (default: false)
#   MANIFEST    — path to manifest file (default: config/subtree-manifest.yml)

set -uo pipefail

MANIFEST="${MANIFEST:-config/subtree-manifest.yml}"
DRY_RUN="${DRY_RUN:-false}"
CMD="${1:-sync}"

info()  { echo "[manage-subtrees] $*" >&2; }
ok()    { echo "[manage-subtrees][ok] $*" >&2; }
warn()  { echo "[manage-subtrees][warn] $*" >&2; }
dry()   { echo "[manage-subtrees][dry-run] $*" >&2; }
fail()  { echo "[manage-subtrees][error] $1" >&2; exit "${2:-1}"; }

[[ -f "$MANIFEST" ]] || fail "Manifest not found: $MANIFEST"

# ── YAML helpers ──────────────────────────────────────────────────────────────
manifest_get() {
  python3 -c "
import yaml, json, sys
d = yaml.safe_load(open('$MANIFEST'))
keys = '$1'.split('.')
v = d
for k in keys:
    v = (v or {}).get(k) if isinstance(v, dict) else None
    if v is None: break
print(json.dumps(v) if v is not None else 'null')
" 2>/dev/null
}

manifest_list() {
  python3 -c "
import yaml, json
d = yaml.safe_load(open('$MANIFEST'))
items = d.get('$1', []) or []
print(json.dumps(items))
" 2>/dev/null
}

# ── Subtree operations ────────────────────────────────────────────────────────
add_subtree() {
  local name="$1" remote="$2" branch="$3" prefix="$4" squash="${5:-true}"
  info "Adding subtree: ${name} → ${prefix} (${remote}@${branch})"

  if [[ -d "$prefix" ]]; then
    info "  ${prefix} already exists — pulling instead"
    pull_subtree "$name" "$remote" "$branch" "$prefix" "$squash"
    return
  fi

  local squash_flag=""
  [[ "$squash" == "true" ]] && squash_flag="--squash"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "git subtree add --prefix=${prefix} ${remote} ${branch} ${squash_flag}"
    return
  fi

  git subtree add --prefix="$prefix" "$remote" "$branch" $squash_flag \
    && ok "Added subtree ${name} at ${prefix}" \
    || warn "Failed to add subtree ${name}"
}

pull_subtree() {
  local name="$1" remote="$2" branch="$3" prefix="$4" squash="${5:-true}"
  info "Pulling subtree: ${name} (${remote}@${branch})"

  local squash_flag=""
  [[ "$squash" == "true" ]] && squash_flag="--squash"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "git subtree pull --prefix=${prefix} ${remote} ${branch} ${squash_flag}"
    return
  fi

  git subtree pull --prefix="$prefix" "$remote" "$branch" $squash_flag \
    && ok "Pulled subtree ${name}" \
    || warn "Failed to pull subtree ${name} (may already be up to date)"
}

sync_subtrees() {
  local subtrees
  subtrees=$(manifest_list "subtrees")
  local count
  count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$subtrees" 2>/dev/null || echo 0)
  info "Syncing ${count} subtree(s)..."

  python3 - "$subtrees" << 'PYEOF'
import json, sys, subprocess, os

items = json.loads(sys.argv[1])
dry = os.environ.get('DRY_RUN', 'false') == 'true'

for item in items:
    name   = item.get('name', '')
    remote = item.get('remote', '')
    branch = item.get('branch', 'main')
    prefix = item.get('prefix', f'vendor/{name}')
    squash = item.get('squash', True)
    msg    = item.get('message', f'chore: sync {name} subtree')

    if not name or not remote:
        print(f"[manage-subtrees][warn] skipping entry with missing name/remote", file=sys.stderr)
        continue

    args = ['git', 'subtree']
    action = 'pull' if os.path.isdir(prefix) else 'add'
    args += [action, f'--prefix={prefix}', remote, branch]
    if squash:
        args.append('--squash')
    if action == 'add':
        args += ['-m', msg]

    print(f"[manage-subtrees] {action} subtree {name} → {prefix}", file=sys.stderr)
    if dry:
        print(f"[manage-subtrees][dry-run] {' '.join(args)}", file=sys.stderr)
    else:
        result = subprocess.run(args, capture_output=False)
        if result.returncode != 0:
            print(f"[manage-subtrees][warn] {action} failed for {name}", file=sys.stderr)
        else:
            print(f"[manage-subtrees][ok] {name}", file=sys.stderr)
PYEOF
}

# ── Submodule operations ──────────────────────────────────────────────────────
add_submodule() {
  local name="$1" url="$2" path="$3" branch="${4:-main}" shallow="${5:-false}"
  info "Adding submodule: ${name} → ${path} (${url}@${branch})"

  if [[ -d "${path}/.git" ]] || grep -q "path = ${path}" .gitmodules 2>/dev/null; then
    info "  ${path} already registered — updating"
    update_submodule "$path" "$branch"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "git submodule add -b ${branch} ${url} ${path}"
    return
  fi

  local depth_flag=""
  [[ "$shallow" == "true" ]] && depth_flag="--depth=1"

  git submodule add -b "$branch" "$url" "$path" \
    && git submodule update --init $depth_flag "$path" \
    && ok "Added submodule ${name} at ${path}" \
    || warn "Failed to add submodule ${name}"
}

update_submodule() {
  local path="$1" branch="${2:-}"
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "git submodule update --remote --merge ${path}"
    return
  fi
  git submodule update --remote --merge "$path" 2>/dev/null \
    && ok "Updated submodule at ${path}" \
    || warn "Failed to update submodule at ${path}"
}

sync_submodules() {
  local submodules
  submodules=$(manifest_list "submodules")
  local count
  count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$submodules" 2>/dev/null || echo 0)
  info "Syncing ${count} submodule(s)..."

  python3 - "$submodules" << 'PYEOF'
import json, sys, subprocess, os

items = json.loads(sys.argv[1])
dry = os.environ.get('DRY_RUN', 'false') == 'true'

for item in items:
    name    = item.get('name', '')
    url     = item.get('url', '')
    path    = item.get('path', f'modules/{name}')
    branch  = item.get('branch', 'main')
    shallow = item.get('shallow', False)

    if not name or not url:
        print(f"[manage-subtrees][warn] skipping submodule with missing name/url", file=sys.stderr)
        continue

    already = os.path.isdir(os.path.join(path, '.git')) or (
        os.path.exists('.gitmodules') and
        f'path = {path}' in open('.gitmodules').read()
    )

    if already:
        print(f"[manage-subtrees] updating submodule {name}", file=sys.stderr)
        args = ['git', 'submodule', 'update', '--remote', '--merge', path]
    else:
        print(f"[manage-subtrees] adding submodule {name} → {path}", file=sys.stderr)
        args = ['git', 'submodule', 'add', '-b', branch, url, path]

    if dry:
        print(f"[manage-subtrees][dry-run] {' '.join(args)}", file=sys.stderr)
    else:
        result = subprocess.run(args, capture_output=False)
        if result.returncode != 0:
            print(f"[manage-subtrees][warn] failed for {name}", file=sys.stderr)
        elif not already:
            depth = ['--depth=1'] if shallow else []
            subprocess.run(['git', 'submodule', 'update', '--init'] + depth + [path])
            print(f"[manage-subtrees][ok] {name}", file=sys.stderr)
PYEOF
}

# ── Umbrella operations ───────────────────────────────────────────────────────
umbrella_init() {
  local enabled
  enabled=$(manifest_get "umbrella.enabled")
  if [[ "$enabled" != "true" ]]; then
    info "Umbrella mode disabled in manifest — skipping"
    return
  fi

  local prefix
  prefix=$(manifest_get "umbrella.prefix" | tr -d '"')
  prefix="${prefix:-repos}"

  info "Initialising umbrella repo (prefix: ${prefix})..."

  python3 - "$prefix" << 'PYEOF'
import yaml, json, sys, subprocess, os

manifest = yaml.safe_load(open(os.environ.get('MANIFEST', 'config/subtree-manifest.yml')))
prefix = sys.argv[1]
children = (manifest.get('umbrella') or {}).get('children') or []
dry = os.environ.get('DRY_RUN', 'false') == 'true'

os.makedirs(prefix, exist_ok=True)

for child in children:
    name   = child.get('name', '')
    url    = child.get('url', '')
    branch = child.get('branch', 'main')
    path   = f"{prefix}/{name}"

    if not name or not url:
        continue

    already = os.path.exists('.gitmodules') and f'path = {path}' in open('.gitmodules').read()
    if already:
        print(f"[manage-subtrees] umbrella: {name} already registered", file=sys.stderr)
        continue

    print(f"[manage-subtrees] umbrella: adding {name} → {path}", file=sys.stderr)
    if dry:
        print(f"[manage-subtrees][dry-run] git submodule add -b {branch} {url} {path}", file=sys.stderr)
    else:
        result = subprocess.run(['git', 'submodule', 'add', '-b', branch, url, path])
        if result.returncode == 0:
            subprocess.run(['git', 'submodule', 'update', '--init', '--depth=1', path])
            print(f"[manage-subtrees][ok] {name}", file=sys.stderr)
        else:
            print(f"[manage-subtrees][warn] failed to add {name}", file=sys.stderr)
PYEOF
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  info "=== Subtree status ==="
  python3 -c "
import yaml, os
d = yaml.safe_load(open('$MANIFEST'))
for s in (d.get('subtrees') or []):
    p = s.get('prefix', '')
    exists = os.path.isdir(p)
    print(f\"  {'✅' if exists else '❌'} {s['name']} → {p}\")
" 2>/dev/null || true

  info "=== Submodule status ==="
  if [[ -f ".gitmodules" ]]; then
    git submodule status 2>/dev/null || true
  else
    info "  No .gitmodules file"
  fi

  info "=== Umbrella status ==="
  python3 -c "
import yaml, os
d = yaml.safe_load(open('$MANIFEST'))
u = d.get('umbrella') or {}
if not u.get('enabled'):
    print('  Umbrella mode disabled')
else:
    prefix = u.get('prefix', 'repos')
    for c in (u.get('children') or []):
        p = f\"{prefix}/{c['name']}\"
        exists = os.path.isdir(p)
        print(f\"  {'✅' if exists else '❌'} {c['name']} → {p}\")
" 2>/dev/null || true
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
  sync)
    sync_subtrees
    sync_submodules
    umbrella_init
    ;;
  add-subtree)
    [[ $# -ge 5 ]] || fail "Usage: manage-subtrees.sh add-subtree <name> <remote> <branch> <prefix>"
    add_subtree "$2" "$3" "$4" "$5" "${6:-true}"
    ;;
  pull-subtree)
    [[ $# -ge 2 ]] || fail "Usage: manage-subtrees.sh pull-subtree <name>"
    name="$2"
    python3 -c "
import yaml, json
d = yaml.safe_load(open('$MANIFEST'))
for s in (d.get('subtrees') or []):
    if s['name'] == '$name':
        print(s['remote'], s.get('branch','main'), s.get('prefix', f'vendor/$name'), s.get('squash', True))
        break
" | read -r remote branch prefix squash
    pull_subtree "$name" "$remote" "$branch" "$prefix" "$squash"
    ;;
  add-submodule)
    [[ $# -ge 4 ]] || fail "Usage: manage-subtrees.sh add-submodule <name> <url> <path> [branch]"
    add_submodule "$2" "$3" "$4" "${5:-main}" "${6:-false}"
    ;;
  update-submodules)
    sync_submodules
    ;;
  umbrella-init)
    umbrella_init
    ;;
  status)
    show_status
    ;;
  *)
    fail "Unknown command: $CMD. Valid: sync, add-subtree, pull-subtree, add-submodule, update-submodules, umbrella-init, status"
    ;;
esac
