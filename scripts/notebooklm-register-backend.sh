#!/usr/bin/env bash
# scripts/notebooklm-register-backend.sh — append a new backend to the registry
#
# Called by generate-notebooklm.yml register-backend job.
# Reads NEW_ID, NEW_NAME, NEW_REPO, NEW_TYPE, NEW_CAPS, NEW_DESC from env.
# Validates inputs, appends to config/notebooklm-backends.yml, creates docs dir.
set -uo pipefail

info() { echo "[notebooklm-register] $*" >&2; }
die()  { echo "[error] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${SCRIPT_DIR}/../config/notebooklm-backends.yml"

: "${NEW_ID:?NEW_ID is required}"
: "${NEW_NAME:?NEW_NAME is required}"
: "${NEW_DESC:?NEW_DESC is required}"
NEW_REPO="${NEW_REPO:-}"
NEW_TYPE="${NEW_TYPE:-self-hosted}"
NEW_CAPS="${NEW_CAPS:-audio-overview}"

# Validate ID format (lowercase, hyphens only)
if ! echo "$NEW_ID" | grep -qE '^[a-z0-9][a-z0-9-]+$'; then
  die "new_backend_id must be lowercase alphanumeric with hyphens: '${NEW_ID}'"
fi

# Check for duplicate
python3 -c "
import yaml, sys
with open('${REGISTRY}') as f:
    cfg = yaml.safe_load(f)
ids = [b['id'] for b in cfg.get('backends', [])]
if '${NEW_ID}' in ids:
    print('::error::Backend ID already exists: ${NEW_ID}', file=sys.stderr)
    sys.exit(1)
print('ID is unique')
" || die "Duplicate backend ID: ${NEW_ID}"

# Build capabilities list
caps_yaml=$(echo "$NEW_CAPS" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed '/^$/d' | sed 's/^/      - /')

# Append to registry
cat >> "$REGISTRY" << ENTRY_EOF

  - id: ${NEW_ID}
    name: ${NEW_NAME}
    repo: "${NEW_REPO}"
    enabled: true
    docs_dir: docs/${NEW_ID}
    description: ${NEW_DESC}
    type: ${NEW_TYPE}
    auth: []
    capabilities:
${caps_yaml}
    notes: "Added via workflow_dispatch on $(date -u '+%Y-%m-%d'). Update auth and notes as needed."
ENTRY_EOF

info "Appended ${NEW_ID} to ${REGISTRY}"

# Validate the registry still parses cleanly
python3 -c "
import yaml
with open('${REGISTRY}') as f:
    yaml.safe_load(f)
print('Registry YAML OK')
" || die "Registry YAML is invalid after append — check formatting"

# Create docs directory skeleton
DOCS_DIR="${SCRIPT_DIR}/../docs/${NEW_ID}"
mkdir -p "${DOCS_DIR}/audio-overview/standard"

cat > "${DOCS_DIR}/README.md" << README_EOF
# ${NEW_NAME}

Generated outputs from [${NEW_NAME}](https://github.com/${NEW_REPO})
using fork-sync-all documentation as source material.

Configured in [\`config/notebooklm-backends.yml\`](../../config/notebooklm-backends.yml)
under \`id: ${NEW_ID}\`.

## Generating content

\`\`\`bash
gh workflow run generate-notebooklm.yml \\
  --field backend=${NEW_ID} \\
  --field content_types=audio-overview
\`\`\`
README_EOF

info "Created docs/${NEW_ID}/ skeleton"
info "Done — review config/notebooklm-backends.yml to add auth secrets and notes"
