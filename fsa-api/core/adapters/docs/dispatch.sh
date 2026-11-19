#!/usr/bin/env bash
# POST /api/fsa/docs/dispatch
# Dispatches any docs/publishing workflow by name with optional inputs.
#
# Body (JSON):
#   {
#     "workflow": "deploy-book",        -- filename stem or display name
#     "ref": "main",                    -- branch/tag (default: main)
#     "inputs": { "engine": "mdbook" }  -- workflow_dispatch inputs
#   }
#
# Returns: { "ok": true, "workflow": "...", "run_url": "..." }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

WORKFLOW="${BODY_workflow:-}"
REF="${BODY_ref:-main}"
INPUTS_JSON="${BODY_inputs:-{}}"

if [[ -z "$WORKFLOW" ]]; then
  fsa_error "workflow is required" 400
  exit 0
fi

# Docs workflow allowlist — only docs/publishing workflows are reachable here
DOCS_STEMS="book-export deploy-book generate-book-pages update-book-index
sync-eggs-docs-to-book gitbook-oss create-readmes update-readmes lts-readmes
readme-wizard validate-readme-render translate-readmes trigger-readme-update
translate-docs generate-sbom generate-notebooklm refresh-notebooklm-auth
upload-notebooklm generate-dep-graph generate-repo-descriptions
update-workflow-triggers-doc"

# Resolve workflow filename
resolve_docs_workflow() {
  local name="$1"
  local wf_dir="${_FSA_ROOT}/.github/workflows"
  # Exact filename
  [[ -f "${wf_dir}/${name}" ]] && echo "$name" && return
  [[ -f "${wf_dir}/${name}.yml" ]] && echo "${name}.yml" && return
  [[ -f "${wf_dir}/${name}.yaml" ]] && echo "${name}.yaml" && return
  # Match by display name
  for f in "${wf_dir}"/*.yml "${wf_dir}"/*.yaml; do
    [[ -f "$f" ]] || continue
    wname=$(python3 -c "import yaml; d=yaml.safe_load(open('$f')); print(d.get('name',''))" 2>/dev/null || echo "")
    [[ "$wname" == "$name" ]] && echo "$(basename "$f")" && return
  done
  echo ""
}

workflow_file=$(resolve_docs_workflow "$WORKFLOW")
if [[ -z "$workflow_file" ]]; then
  fsa_error "docs workflow not found: ${WORKFLOW}" 404
  exit 0
fi

# Enforce allowlist
stem="${workflow_file%.yml}"
stem="${stem%.yaml}"
if ! echo "$DOCS_STEMS" | grep -qw "$stem"; then
  fsa_error "workflow '${stem}' is not in the docs/publishing allowlist" 403
  exit 0
fi

fsa_quota_check 30 || exit 0

# Dispatch
fsa_api_post \
  "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/dispatches" \
  "{\"ref\":\"${REF}\",\"inputs\":${INPUTS_JSON}}" > /dev/null

sleep 2
runs=$(fsa_api_get "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/runs?per_page=1")
run_url=$(echo "$runs" | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs=d.get('workflow_runs',[])
print(runs[0].get('html_url','') if runs else '')
" 2>/dev/null || echo "")

echo "{\"ok\":true,\"workflow\":\"${workflow_file}\",\"ref\":\"${REF}\",\"run_url\":\"${run_url}\"}"
