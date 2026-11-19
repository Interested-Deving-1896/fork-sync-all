#!/usr/bin/env bash
#
# scripts/reconcile-identity-assets.sh
#
# Detects which fork-sync-all instance this is running on, selects the
# matching brand variant from assets/brand/<variant>/, and writes the
# active assets to assets/brand/.active/ (gitignored, never committed).
#
# Also injects identity content into DOCS/cover.md via <!-- FSA-IDENTITY-* -->
# marker pairs, similar to how FSA-COUNTS works in README.md.
#
# Safe to run on any instance — the source instance gets its own variant,
# mirrors get theirs. The variant store dirs are identical on all instances
# (all three variants are committed everywhere), so the GitLab→GitHub pull
# leg cannot corrupt the source variant.
#
# Usage:
#   bash scripts/reconcile-identity-assets.sh [--dry-run] [--deployment-id ID]
#
# Options:
#   --dry-run          Print what would change without writing anything
#   --deployment-id ID Override auto-detected deployment ID
#
# Required env (for auto-detection):
#   GH_TOKEN           GitHub token (used by fsa-node-identity.sh)
#   GITHUB_REPOSITORY  Set automatically in GitHub Actions
#
# Optional env:
#   FSA_CHAIN_POSITION Override chain position (source | mirror | downstream-fork)
#   REPO_ROOT          Path to repo root (default: auto-detected)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

info()  { echo "[reconcile-identity] $*" >&2; }
warn()  { echo "[reconcile-identity] WARN: $*" >&2; }
dry()   { echo "[reconcile-identity] [dry-run] $*" >&2; }
die()   { echo "[reconcile-identity] ERROR: $*" >&2; exit 1; }

DRY_RUN=false
OVERRIDE_DEPLOYMENT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=true; shift ;;
    --deployment-id)   OVERRIDE_DEPLOYMENT_ID="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

IDENTITY_CONFIG="${REPO_ROOT}/config/identity-assets.yml"
BRAND_DIR="${REPO_ROOT}/assets/brand"
ACTIVE_DIR="${BRAND_DIR}/.active"
COVER_FILE="${REPO_ROOT}/DOCS/cover.md"

[[ -f "$IDENTITY_CONFIG" ]] || die "identity-assets.yml not found: ${IDENTITY_CONFIG}"
[[ -d "$BRAND_DIR" ]]       || die "assets/brand/ not found: ${BRAND_DIR}"

# ── Detect deployment ID ──────────────────────────────────────────────────────

detect_deployment_id() {
  # 1. Explicit override
  if [[ -n "$OVERRIDE_DEPLOYMENT_ID" ]]; then
    echo "$OVERRIDE_DEPLOYMENT_ID"
    return
  fi

  # 2. Source instance — canonical slug
  local repo="${GITHUB_REPOSITORY:-}"
  if [[ "$repo" == "Interested-Deving-1896/fork-sync-all" ]]; then
    echo "source"
    return
  fi

  # 3. Mirror instances — detect by GITHUB_REPOSITORY_OWNER or FSA_UPSTREAM_OWNER
  local owner="${GITHUB_REPOSITORY_OWNER:-}"
  case "$owner" in
    OpenOS-Project-OSP)                echo "osp-github"; return ;;
    OpenOS-Project-Ecosystem-OOC)      echo "ooc-github"; return ;;
    openos-project)                    echo "osp-gitlab";  return ;;
    openos-project-ooc-ecosystem)      echo "ooc-gitlab";  return ;;
  esac

  # 4. CI_PROJECT_NAMESPACE (GitLab CI)
  local ns="${CI_PROJECT_NAMESPACE:-}"
  case "$ns" in
    openos-project)                    echo "osp-gitlab";  return ;;
    openos-project-ooc-ecosystem)      echo "ooc-gitlab";  return ;;
  esac

  # 5. FSA_CHAIN_POSITION override
  local pos="${FSA_CHAIN_POSITION:-}"
  if [[ "$pos" == "source" ]]; then
    echo "source"
    return
  fi

  # 6. Default — assume source (safe: source variant is the canonical one)
  warn "Could not detect deployment ID — defaulting to 'source'"
  echo "source"
}

DEPLOYMENT_ID=$(detect_deployment_id)
info "Deployment ID: ${DEPLOYMENT_ID}"

# ── Look up variant for this deployment ──────────────────────────────────────

lookup_variant() {
  local dep_id="$1"
  python3 - "$dep_id" "$IDENTITY_CONFIG" << 'PYEOF'
import sys, yaml
dep_id = sys.argv[1]
config_path = sys.argv[2]
with open(config_path) as f:
    config = yaml.safe_load(f) or {}
for v in config.get("variants", []):
    if v.get("deployment_id") == dep_id:
        print(v.get("variant", ""))
        sys.exit(0)
sys.exit(1)
PYEOF
}

lookup_field() {
  local dep_id="$1" field="$2"
  python3 - "$dep_id" "$field" "$IDENTITY_CONFIG" << 'PYEOF'
import sys, yaml
dep_id, field, config_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(config_path) as f:
    config = yaml.safe_load(f) or {}
for v in config.get("variants", []):
    if v.get("deployment_id") == dep_id:
        print(v.get(field, ""))
        sys.exit(0)
sys.exit(1)
PYEOF
}

VARIANT=$(lookup_variant "$DEPLOYMENT_ID") || die "No variant found for deployment_id='${DEPLOYMENT_ID}'"
VARIANT_DIR="${BRAND_DIR}/${VARIANT}"
DISPLAY_NAME=$(lookup_field "$DEPLOYMENT_ID" "display_name")
BADGE_COLOR=$(lookup_field "$DEPLOYMENT_ID" "badge_color")
DOCS_URL=$(lookup_field "$DEPLOYMENT_ID" "docs_url")

info "Variant:      ${VARIANT} (${DISPLAY_NAME})"
info "Variant dir:  ${VARIANT_DIR}"

[[ -d "$VARIANT_DIR" ]] || die "Variant directory not found: ${VARIANT_DIR}"

# ── Copy assets to .active/ ───────────────────────────────────────────────────

copy_assets() {
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would create ${ACTIVE_DIR}/"
  else
    mkdir -p "$ACTIVE_DIR"
  fi

  python3 - "$IDENTITY_CONFIG" << 'PYEOF'
import sys, yaml
config_path = sys.argv[1]
with open(config_path) as f:
    config = yaml.safe_load(f) or {}
for af in config.get("asset_files", []):
    print(af["source_file"], af.get("required", False))
PYEOF
  while IFS=" " read -r source_file required; do
    local src="${VARIANT_DIR}/${source_file}"
    local dst="${ACTIVE_DIR}/${source_file}"
    if [[ -f "$src" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "would copy ${src} → ${dst}"
      else
        cp "$src" "$dst"
        info "  copied: ${source_file}"
      fi
    else
      if [[ "$required" == "True" ]]; then
        warn "Required asset missing: ${src}"
      else
        info "  skipped (absent): ${source_file}"
      fi
    fi
  done
}

copy_assets

# ── Inject identity into DOCS/cover.md ───────────────────────────────────────

inject_cover() {
  [[ -f "$COVER_FILE" ]] || { warn "cover.md not found — skipping injection"; return; }

  local cover
  cover=$(cat "$COVER_FILE")

  # Inject each marker
  python3 - "$COVER_FILE" "$IDENTITY_CONFIG" "$VARIANT_DIR" "$DEPLOYMENT_ID" \
            "$DISPLAY_NAME" "$BADGE_COLOR" "$DOCS_URL" "$DRY_RUN" << 'PYEOF'
import sys, yaml, re, os

cover_file    = sys.argv[1]
config_path   = sys.argv[2]
variant_dir   = sys.argv[3]
dep_id        = sys.argv[4]
display_name  = sys.argv[5]
badge_color   = sys.argv[6]
docs_url      = sys.argv[7]
dry_run       = sys.argv[8] == "true"

with open(config_path) as f:
    config = yaml.safe_load(f) or {}

with open(cover_file) as f:
    content = f.read()

changed = False

for marker_def in config.get("cover_markers", []):
    marker     = marker_def["marker"]
    source     = marker_def.get("source", "")
    start_tag  = f"<!-- {marker}-START -->"
    end_tag    = f"<!-- {marker}-END -->"

    if start_tag not in content:
        continue  # marker not present in this cover.md — skip

    # Build replacement content
    replacement = ""
    if source:
        src_path = os.path.join(variant_dir, source)
        if os.path.exists(src_path):
            with open(src_path) as sf:
                replacement = sf.read().strip()
        elif marker == "FSA-IDENTITY-LOGO":
            replacement = ""  # logo is optional — emit nothing
        # cover-badge-extra is also optional
    elif marker == "FSA-IDENTITY-LOGO" and not source:
        replacement = ""

    new_block = f"{start_tag}\n{replacement}\n{end_tag}"
    pattern   = re.compile(
        re.escape(start_tag) + r".*?" + re.escape(end_tag),
        re.DOTALL
    )
    new_content = pattern.sub(new_block, content)
    if new_content != content:
        content = new_content
        changed = True
        print(f"[reconcile-identity]   injected: {marker}", file=sys.stderr)

if changed:
    if dry_run:
        print(f"[reconcile-identity] [dry-run] would update {cover_file}", file=sys.stderr)
    else:
        with open(cover_file, "w") as f:
            f.write(content)
        print(f"[reconcile-identity] updated: {cover_file}", file=sys.stderr)
else:
    print(f"[reconcile-identity] cover.md: no changes", file=sys.stderr)
PYEOF
}

inject_cover

# ── Write .active/identity.env for downstream consumers ──────────────────────
# Shell-sourceable env file so other scripts can read identity vars without
# re-parsing YAML.

write_identity_env() {
  local env_file="${ACTIVE_DIR}/identity.env"
  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would write ${env_file}"
    return
  fi
  mkdir -p "$ACTIVE_DIR"
  cat > "$env_file" << EOF
# Auto-generated by reconcile-identity-assets.sh — do not edit
FSA_IDENTITY_DEPLOYMENT_ID="${DEPLOYMENT_ID}"
FSA_IDENTITY_VARIANT="${VARIANT}"
FSA_IDENTITY_DISPLAY_NAME="${DISPLAY_NAME}"
FSA_IDENTITY_BADGE_COLOR="${BADGE_COLOR}"
FSA_IDENTITY_DOCS_URL="${DOCS_URL}"
FSA_IDENTITY_LOGO_SVG="${ACTIVE_DIR}/logo.svg"
FSA_IDENTITY_LOGO_PNG="${ACTIVE_DIR}/logo.png"
EOF
  info "wrote: ${env_file}"
}

write_identity_env

# ── Generate per-instance theme CSS override ──────────────────────────────────
# Writes .active/theme-override.css with CSS custom property overrides for the
# active variant's color palette. deploy-book.yml injects this after
# vendor/book-engine/themes/fsa/custom.css so instance colors win.

generate_theme_css() {
  local css_file="${ACTIVE_DIR}/theme-override.css"

  local primary primary_light primary_dark accent accent_light cyan cyan_light
  primary=$(python3 -c "
import yaml,sys
dep_id=sys.argv[1]; path=sys.argv[2]
with open(path) as f: d=yaml.safe_load(f)
for v in d.get('variants',[]):
    if v.get('deployment_id')==dep_id:
        t=v.get('theme',{})
        print(t.get('primary','#0033cc'))
        break
" "$DEPLOYMENT_ID" "$IDENTITY_CONFIG" 2>/dev/null || echo "#0033cc")

  # Read all theme fields in one python call
  read -r primary primary_light primary_dark accent accent_light cyan cyan_light < <(python3 -c "
import yaml,sys
dep_id=sys.argv[1]; path=sys.argv[2]
with open(path) as f: d=yaml.safe_load(f)
for v in d.get('variants',[]):
    if v.get('deployment_id')==dep_id:
        t=v.get('theme',{})
        print(
            t.get('primary','#0033cc'),
            t.get('primary_light','#3366ff'),
            t.get('primary_dark','#001a80'),
            t.get('accent','#cc0000'),
            t.get('accent_light','#ff3333'),
            t.get('cyan','#00aacc'),
            t.get('cyan_light','#33ccee'),
        )
        break
" "$DEPLOYMENT_ID" "$IDENTITY_CONFIG" 2>/dev/null || echo "#0033cc #3366ff #001a80 #cc0000 #ff3333 #00aacc #33ccee")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would write ${css_file} (primary=${primary})"
    return
  fi

  mkdir -p "$ACTIVE_DIR"
  cat > "$css_file" << EOF
/* Auto-generated by reconcile-identity-assets.sh — do not edit.
 * Per-instance color overrides for ${DISPLAY_NAME}.
 * Injected after vendor/book-engine/themes/fsa/custom.css by deploy-book.yml. */
:root {
    --fsa-blue:        ${primary};
    --fsa-blue-light:  ${primary_light};
    --fsa-blue-dark:   ${primary_dark};
    --fsa-red:         ${accent};
    --fsa-red-light:   ${accent_light};
    --fsa-cyan:        ${cyan};
    --fsa-cyan-light:  ${cyan_light};
}
EOF
  info "wrote: ${css_file} (primary=${primary})"
}

generate_theme_css

# ── Patch book.toml for this instance ────────────────────────────────────────
# Writes .active/book-toml-patch.py — a Python script that deploy-book.yml
# runs to patch book.toml in-place before mdbook build. Patches:
#   site-url, git-repository-url, edit-url-template, additional-css (append override)
# The patch is non-destructive: it only modifies the listed keys and appends
# the theme override CSS path. book.toml is restored after build by deploy-book.yml.

generate_book_toml_patch() {
  local patch_file="${ACTIVE_DIR}/book-toml-patch.py"

  local site_url repo_url edit_url_template
  read -r site_url repo_url edit_url_template < <(python3 -c "
import yaml,sys,shlex
dep_id=sys.argv[1]; path=sys.argv[2]
with open(path) as f: d=yaml.safe_load(f)
for v in d.get('variants',[]):
    if v.get('deployment_id')==dep_id:
        bt=v.get('book_toml',{})
        print(
            shlex.quote(bt.get('site_url','/')),
            shlex.quote(bt.get('repo_url','')),
            shlex.quote(bt.get('edit_url_template','')),
        )
        break
" "$DEPLOYMENT_ID" "$IDENTITY_CONFIG" 2>/dev/null || echo "'/' '' ''")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would write ${patch_file}"
    return
  fi

  mkdir -p "$ACTIVE_DIR"
  # Write the patch script — uses tomlkit if available, falls back to regex
  cat > "$patch_file" << 'PYEOF'
#!/usr/bin/env python3
"""Patch book.toml with per-instance identity values.
Called by deploy-book.yml before mdbook build.
Usage: python3 book-toml-patch.py <book_toml_path> <site_url> <repo_url> <edit_url_template> <override_css_path>
"""
import sys, re, os

book_toml_path   = sys.argv[1]
site_url         = sys.argv[2]
repo_url         = sys.argv[3]
edit_url_template = sys.argv[4]
override_css     = sys.argv[5]  # relative path from repo root

with open(book_toml_path) as f:
    content = f.read()

original = content

def replace_toml_str(content, key, value):
    """Replace a TOML string value for a given key."""
    pattern = re.compile(r'(?m)^(' + re.escape(key) + r'\s*=\s*)"[^"]*"')
    replacement = r'\1"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
    new = pattern.sub(replacement, content)
    if new == content:
        print(f"  [book-toml-patch] key not found, skipping: {key}", file=sys.stderr)
    return new

if site_url:
    content = replace_toml_str(content, 'site-url', site_url)
if repo_url:
    content = replace_toml_str(content, 'git-repository-url', repo_url)
if edit_url_template:
    content = replace_toml_str(content, 'edit-url-template', edit_url_template)

# Append theme override CSS to additional-css list if not already present
if override_css and override_css not in content:
    pattern = re.compile(r'(additional-css\s*=\s*\[)([^\]]*?)(\])', re.DOTALL)
    def add_css(m):
        existing = m.group(2).rstrip()
        sep = ', ' if existing.strip() else ''
        return m.group(1) + existing + sep + f'"{override_css}"' + m.group(3)
    new = pattern.sub(add_css, content)
    if new != content:
        content = new
        print(f"  [book-toml-patch] appended: {override_css}", file=sys.stderr)

if content != original:
    with open(book_toml_path, 'w') as f:
        f.write(content)
    print(f"  [book-toml-patch] patched: {book_toml_path}", file=sys.stderr)
else:
    print(f"  [book-toml-patch] no changes needed", file=sys.stderr)
PYEOF
  chmod +x "$patch_file"
  info "wrote: ${patch_file}"
}

generate_book_toml_patch

info "Done. Active assets in: ${ACTIVE_DIR}"
