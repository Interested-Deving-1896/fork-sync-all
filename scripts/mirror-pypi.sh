#!/usr/bin/env bash
#
# Re-publish PyPI packages from UPSTREAM_OWNER repos to OSP/OOC with
# org-prefixed package names (e.g. osp-linux-kernel-manager).
#
# For each repo with a publish.yml that targets PyPI:
#   1. Download the sdist/wheel from the upstream GitHub Release assets
#   2. Rewrite the package name in pyproject.toml to add the org prefix
#   3. Rebuild the distribution
#   4. Publish via trusted publishing (OIDC) to PyPI
#
# This script is called from within the OSP/OOC repo's own publish workflow,
# so OIDC trusted publishing works (the workflow runs in the correct repo).
#
# Env vars required:
#   UPSTREAM_OWNER, UPSTREAM_REPO, ORG_PREFIX (e.g. "osp"), RELEASE_TAG
#
set -uo pipefail

: "${UPSTREAM_OWNER:?required}"
: "${UPSTREAM_REPO:?required}"
: "${ORG_PREFIX:?required}"   # e.g. "osp" or "ooc"
: "${RELEASE_TAG:?required}"  # e.g. "v0.1.2"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN:-}" -H "Accept: application/vnd.github+json")

# ── API helper with rate-limit retry ─────────────────────────────────────────
# GitHub REST primary limit: 5 000 req/hr per token.
# HTTP 403/429 indicates secondary (burst) rate limiting; X-RateLimit-Reset
# header gives the epoch second when the window resets.
_API_HEADER=$(mktemp)
trap 'rm -f "$_API_HEADER"' EXIT

api_get() {
  local max_retries=3 attempt=0
  while true; do
    local out http_code
    out=$(curl --disable --silent -w "
%{http_code}" \
      -D "$_API_HEADER" \
      "${AUTH[@]}" "$@" 2>/dev/null) || true
    http_code=$(echo "$out" | tail -1)
    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$out" | sed '$d'; return 1; fi
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$_API_HEADER" 2>/dev/null | tr -d '' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      if [[ -n "$reset" && "$wait" -gt 0 && "$wait" -lt 3700 ]]; then
        echo "  [rate-limit] HTTP ${http_code} — sleeping ${wait}s (attempt ${attempt}/${max_retries})" >&2
        sleep "$wait"
      else
        echo "  [rate-limit] HTTP ${http_code} — backing off 60s (attempt ${attempt}/${max_retries})" >&2
        sleep 60
      fi
      continue
    fi
    echo "$out" | sed '$d'
    return 0
  done
}

echo "Mirroring PyPI: ${UPSTREAM_OWNER}/${UPSTREAM_REPO}@${RELEASE_TAG} -> ${ORG_PREFIX}-prefixed"

# 1. Get the release assets (sdist .tar.gz and wheel .whl)
release=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPO}/releases/tags/${RELEASE_TAG}")
assets=$(echo "$release" | jq -r '.assets[] | select(.name | test("\\.(whl|tar\\.gz)$")) | .browser_download_url')

if [[ -z "$assets" ]]; then
  echo "No wheel/sdist assets found in release ${RELEASE_TAG} — building from source instead."
  BUILD_FROM_SOURCE=1
else
  BUILD_FROM_SOURCE=0
fi

mkdir -p dist

if [[ "$BUILD_FROM_SOURCE" == "1" ]]; then
  # Build from the checked-out source (this script runs inside the mirror repo)
  # Rewrite the package name in pyproject.toml
  python3 - "$ORG_PREFIX" << 'PYEOF'
import sys, re, pathlib

prefix = sys.argv[1]
p = pathlib.Path("pyproject.toml")
content = p.read_text()

# Match `name = "foo"` or `name        = "foo"`
def rewrite_name(m):
    orig = m.group(2)
    # Don't double-prefix
    if orig.startswith(f"{prefix}-"):
        return m.group(0)
    return f'{m.group(1)}"{prefix}-{orig}"'

new = re.sub(r'(name\s*=\s*)"([^"]+)"', rewrite_name, content, count=1)
if new == content:
    print(f"WARNING: could not find package name in pyproject.toml")
else:
    p.write_text(new)
    name_match = re.search(r'name\s*=\s*"([^"]+)"', new)
    print(f"Package name rewritten to: {name_match.group(1) if name_match else '?'}")
PYEOF

  pip install build
  python -m build --outdir dist/

else
  # Download pre-built assets and repackage with new name
  echo "Downloading release assets..."
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" EXIT

  while IFS= read -r url; do
    fname=$(basename "$url")
    echo "  Downloading: $fname"
    curl --disable --silent -L -o "${tmpdir}/${fname}" "$url"
  done <<< "$assets"

  # Rewrite wheel metadata name and sdist name
  python3 - "$tmpdir" "$ORG_PREFIX" "dist" << 'PYEOF'
import sys, os, re, zipfile, tarfile, shutil, pathlib

src_dir, prefix, out_dir = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out_dir, exist_ok=True)

def prefix_name(name, prefix):
    if name.startswith(f"{prefix}-") or name.startswith(f"{prefix}_"):
        return name
    return f"{prefix}-{name}"

for fname in os.listdir(src_dir):
    src = os.path.join(src_dir, fname)

    if fname.endswith(".whl"):
        # Wheel filename: {name}-{version}-{python}-{abi}-{platform}.whl
        parts = fname.split("-")
        orig_name = parts[0]
        new_name = prefix_name(orig_name, prefix)
        parts[0] = new_name
        new_fname = "-".join(parts)

        # Rewrite METADATA inside wheel
        with zipfile.ZipFile(src, "r") as zin:
            names = zin.namelist()
            out_path = os.path.join(out_dir, new_fname)
            with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zout:
                for item in names:
                    data = zin.read(item)
                    if item.endswith("/METADATA") or item.endswith(".dist-info/METADATA"):
                        text = data.decode("utf-8", errors="replace")
                        text = re.sub(r'^(Name: )(.+)$',
                            lambda m: f"{m.group(1)}{prefix_name(m.group(2), prefix)}",
                            text, flags=re.MULTILINE)
                        data = text.encode("utf-8")
                    # Rename dist-info directory
                    new_item = item.replace(f"{orig_name}-", f"{new_name}-", 1)
                    zout.writestr(new_item, data)
        print(f"  Repackaged wheel: {new_fname}")

    elif fname.endswith(".tar.gz"):
        # sdist: {name}-{version}.tar.gz
        base = fname[:-7]  # strip .tar.gz
        parts = base.split("-", 1)
        orig_name = parts[0]
        new_name = prefix_name(orig_name, prefix)
        new_base = f"{new_name}-{parts[1]}" if len(parts) > 1 else new_name
        new_fname = f"{new_base}.tar.gz"

        with tarfile.open(src, "r:gz") as tin:
            out_path = os.path.join(out_dir, new_fname)
            with tarfile.open(out_path, "w:gz") as tout:
                for member in tin.getmembers():
                    member.name = member.name.replace(base, new_base, 1)
                    f = tin.extractfile(member)
                    if f is not None:
                        data = f.read()
                        if member.name.endswith("PKG-INFO") or member.name.endswith("pyproject.toml"):
                            text = data.decode("utf-8", errors="replace")
                            text = re.sub(r'^(Name: )(.+)$',
                                lambda m: f"{m.group(1)}{prefix_name(m.group(2), prefix)}",
                                text, flags=re.MULTILINE)
                            text = re.sub(r'(name\s*=\s*)"([^"]+)"',
                                lambda m: f'{m.group(1)}"{prefix_name(m.group(2), prefix)}"',
                                text, count=1)
                            data = text.encode("utf-8")
                        import io
                        tout.addfile(member, io.BytesIO(data))
                    else:
                        tout.addfile(member)
        print(f"  Repackaged sdist: {new_fname}")
PYEOF
fi

echo ""
echo "dist/ contents:"
ls -lh dist/
echo ""
echo "Ready for PyPI publish via trusted publishing."
