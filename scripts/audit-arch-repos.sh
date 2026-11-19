#!/usr/bin/env bash
# Audit which expected repos exist vs are missing.
# Outputs: /tmp/existing_repos.txt, /tmp/missing_repos.txt, /tmp/audit-summary.txt
set -euo pipefail

export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

USER="Interested-Deving-1896"
EXPECTED="/tmp/expected_repos.txt"
EXISTING="/tmp/existing_repos.txt"
MISSING="/tmp/missing_repos.txt"

echo "=== Repo Audit ==="
echo "Started: $(date -u)"

# Generate expected list via dry-run (no API calls)
python3 "$SCRIPT_DIR/create-arch-repos.py" --dry-run \
  --arch amd64 arm64 armhf riscv64 s390x armel ppc64el mips64el loong64 i686 \
  2>&1 | grep "\[dry-run\] gh repo create" \
       | sed "s|.*${USER}/||" \
       | sort > "$EXPECTED"
echo "Expected repos: $(wc -l < "$EXPECTED")"

# Fetch all existing repos (paginated, ~3 API calls for 300 repos)
> "$EXISTING"
page=1
while true; do
  result=$(gh api "users/${USER}/repos?per_page=100&page=${page}" --jq '.[].name' 2>&1)
  if [[ -z "$result" ]] || echo "$result" | grep -q '"message"'; then
    break
  fi
  echo "$result" >> "$EXISTING"
  count=$(echo "$result" | wc -l)
  if [[ "$count" -lt 100 ]]; then break; fi
  ((page++))
done
sort -o "$EXISTING" "$EXISTING"
echo "Existing repos: $(wc -l < "$EXISTING")"

# Diff
comm -23 "$EXPECTED" "$EXISTING" > "$MISSING"
echo "Missing repos:  $(wc -l < "$MISSING")"

# Summary by arch
echo ""
echo "=== Missing by architecture ==="
for arch in amd64 arm64 armhf riscv64 s390x armel ppc64el mips64el loong64 i686; do
  count=$(grep -c "^${arch}-\|^debian-${arch}\|^devuan-${arch}\|^ubuntu-${arch}\|^debian-linux-${arch}\|^devuan-linux-${arch}\|^ubuntu-linux-${arch}\|^debian-cd-${arch}\|^devuan-cd-${arch}\|^ubuntu-cd-${arch}" "$MISSING" 2>/dev/null || echo 0)
  echo "  ${arch}: ${count} missing"
done

echo ""
echo "Missing repo list saved to: $MISSING"
echo "Done: $(date -u)"
