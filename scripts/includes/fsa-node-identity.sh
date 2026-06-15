#!/usr/bin/env bash
#
# scripts/includes/fsa-node-identity.sh — mirror-chain node identity detection
#
# Determines where this fork-sync-all instance sits in the mirror chain and
# what operations it should perform. Extends fsa-mode.sh (managed/autonomous)
# with a position layer: source / mirror / downstream-fork.
#
# ── Chain topology ────────────────────────────────────────────────────────────
#
#   source          — the canonical upstream instance (Interested-Deving-1896).
#                     Runs all operations: mirror-to-osp, mirror-osp-to-gitlab,
#                     readme updates, badge injection, fork sync, etc.
#
#   mirror          — a downstream GitHub mirror (e.g. OpenOS-Project-OSP).
#                     Receives pushes from source; should NOT re-run source
#                     operations. May run GitLab-push and OOC-push legs.
#
#   downstream-fork — an independent fork of fork-sync-all that manages its
#                     own org. Runs all operations scoped to its own org,
#                     not to I-D-1896 or OSP.
#
# ── Detection logic ──────────────────────────────────────────────────────────
#
#   1. FSA_CHAIN_POSITION env var — explicit override (highest priority).
#      Values: source | mirror | downstream-fork
#
#   2. GITHUB_REPOSITORY — if it matches the canonical source slug
#      (Interested-Deving-1896/fork-sync-all), position = source.
#
#   3. FSA_UPSTREAM_OWNER env var — if set, this instance is a mirror of
#      that owner. Position = mirror.
#
#   4. fsa_is_managed() from fsa-mode.sh — if managed by an upstream FSA
#      instance (FSA_MANAGED=true or upstream fork-sync-all exists), and
#      GITHUB_REPOSITORY_OWNER != canonical source owner, position = mirror.
#
#   5. Default — position = downstream-fork (independent instance).
#
# ── Exported variables ────────────────────────────────────────────────────────
#
#   FSA_NODE_POSITION   — source | mirror | downstream-fork
#   FSA_NODE_OWNER      — the org/user this instance manages (its own org)
#   FSA_UPSTREAM_OWNER  — the org being mirrored from (empty for source/fork)
#   FSA_CHAIN_DEPTH     — 0=source, 1=first mirror, 2=second mirror, etc.
#                         (set via FSA_CHAIN_DEPTH env var; defaults to 0 for
#                          source, 1 for mirror, 2 for downstream-fork)
#
# ── Operation capability flags ────────────────────────────────────────────────
#
#   fsa_can_mirror_to_github   — push repos to a downstream GitHub org
#   fsa_can_mirror_to_gitlab   — push repos to a GitLab group
#   fsa_can_update_readmes     — write README files to managed repos
#   fsa_can_inject_badges      — inject built-with-ona badges
#   fsa_can_sync_forks         — sync upstream forks
#   fsa_can_translate          — run translation workflows
#   fsa_can_manage_templates   — push template files to consumer repos
#
#   All return 0 (true) or 1 (false). Callers use:
#     fsa_can_mirror_to_github && bash scripts/mirror-to-osp.sh
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   source scripts/includes/fsa-node-identity.sh
#   fsa_node_detect          # populate FSA_NODE_* vars
#   echo "Position: $FSA_NODE_POSITION"
#   fsa_can_mirror_to_github && echo "will mirror to GitHub"
#
# Guard against double-sourcing
[[ -n "${_FSA_NODE_IDENTITY_LOADED:-}" ]] && return 0
_FSA_NODE_IDENTITY_LOADED=1

# Source fsa-mode.sh for fsa_is_managed()
_FSA_NODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/includes/fsa-mode.sh
source "${_FSA_NODE_DIR}/fsa-mode.sh"

# Canonical source identity — the one true upstream instance.
_FSA_CANONICAL_OWNER="${FSA_CANONICAL_OWNER:-Interested-Deving-1896}"
_FSA_CANONICAL_REPO="${FSA_CANONICAL_REPO:-fork-sync-all}"
_FSA_CANONICAL_SLUG="${_FSA_CANONICAL_OWNER}/${_FSA_CANONICAL_REPO}"

# ── fsa_node_detect ───────────────────────────────────────────────────────────
# Populates FSA_NODE_POSITION, FSA_NODE_OWNER, FSA_UPSTREAM_OWNER,
# FSA_CHAIN_DEPTH. Safe to call multiple times (idempotent after first call).
fsa_node_detect() {
  # Already detected — skip.
  [[ -n "${FSA_NODE_POSITION:-}" ]] && return 0

  local repo="${GITHUB_REPOSITORY:-}"
  local owner="${GITHUB_REPOSITORY_OWNER:-}"

  # ── 1. Explicit override ──────────────────────────────────────────────────
  if [[ -n "${FSA_CHAIN_POSITION:-}" ]]; then
    FSA_NODE_POSITION="${FSA_CHAIN_POSITION}"
    FSA_NODE_OWNER="${owner}"
    FSA_CHAIN_DEPTH="${FSA_CHAIN_DEPTH:-1}"
    echo "[fsa-node] explicit FSA_CHAIN_POSITION=${FSA_NODE_POSITION}" >&2
    _fsa_node_export
    return 0
  fi

  # ── 2. Canonical source slug match ───────────────────────────────────────
  if [[ "$repo" == "${_FSA_CANONICAL_SLUG}" ]]; then
    FSA_NODE_POSITION="source"
    FSA_NODE_OWNER="${_FSA_CANONICAL_OWNER}"
    FSA_UPSTREAM_OWNER=""
    FSA_CHAIN_DEPTH=0
    echo "[fsa-node] canonical source detected (${_FSA_CANONICAL_SLUG})" >&2
    _fsa_node_export
    return 0
  fi

  # ── 3. Explicit upstream owner set — this is a mirror ────────────────────
  if [[ -n "${FSA_UPSTREAM_OWNER:-}" ]]; then
    FSA_NODE_POSITION="mirror"
    FSA_NODE_OWNER="${owner}"
    FSA_CHAIN_DEPTH="${FSA_CHAIN_DEPTH:-1}"
    echo "[fsa-node] FSA_UPSTREAM_OWNER=${FSA_UPSTREAM_OWNER} — mirror mode" >&2
    _fsa_node_export
    return 0
  fi

  # ── 4. Managed by upstream FSA + not canonical owner → mirror ────────────
  if fsa_is_managed 2>/dev/null; then
    if [[ "$owner" != "${_FSA_CANONICAL_OWNER}" ]]; then
      FSA_NODE_POSITION="mirror"
      FSA_NODE_OWNER="${owner}"
      FSA_UPSTREAM_OWNER="${FSA_UPSTREAM_OWNER:-${_FSA_CANONICAL_OWNER}}"
      FSA_CHAIN_DEPTH="${FSA_CHAIN_DEPTH:-1}"
      echo "[fsa-node] managed mode + non-canonical owner → mirror" >&2
      _fsa_node_export
      return 0
    fi
  fi

  # ── 5. Default: independent downstream fork ───────────────────────────────
  FSA_NODE_POSITION="downstream-fork"
  FSA_NODE_OWNER="${owner}"
  FSA_UPSTREAM_OWNER=""
  FSA_CHAIN_DEPTH="${FSA_CHAIN_DEPTH:-2}"
  echo "[fsa-node] no upstream detected — downstream-fork (${owner})" >&2
  _fsa_node_export
}

# _fsa_node_export: write detected values to GITHUB_OUTPUT if available.
_fsa_node_export() {
  export FSA_NODE_POSITION FSA_NODE_OWNER FSA_UPSTREAM_OWNER FSA_CHAIN_DEPTH
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "fsa_node_position=${FSA_NODE_POSITION}"
      echo "fsa_node_owner=${FSA_NODE_OWNER}"
      echo "fsa_upstream_owner=${FSA_UPSTREAM_OWNER:-}"
      echo "fsa_chain_depth=${FSA_CHAIN_DEPTH}"
    } >> "$GITHUB_OUTPUT"
  fi
}

# ── Capability predicates ─────────────────────────────────────────────────────
# Each returns 0 (true) if the current node should perform that operation.
# Call fsa_node_detect first.

# Mirror repos to a downstream GitHub org (e.g. I-D-1896 → OSP).
fsa_can_mirror_to_github() {
  fsa_node_detect
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;  # source always mirrors downstream
    mirror)          return 0 ;;  # mirrors can re-mirror further (OSP → OOC)
    downstream-fork) return 0 ;;  # forks manage their own chain
  esac
  return 1
}

# Push repos to GitLab.
fsa_can_mirror_to_gitlab() {
  fsa_node_detect
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;
    mirror)          return 0 ;;
    downstream-fork) return 0 ;;
  esac
  return 1
}

# Write README files to managed repos.
fsa_can_update_readmes() {
  fsa_node_detect
  # Only the source (or an independent fork) should write READMEs.
  # A mirror that is managed by source should not duplicate this work.
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;
    downstream-fork) return 0 ;;
    mirror)          return 1 ;;  # source handles this
  esac
  return 1
}

# Inject built-with-ona badges.
fsa_can_inject_badges() {
  fsa_node_detect
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;
    downstream-fork) return 0 ;;
    mirror)          return 1 ;;
  esac
  return 1
}

# Sync upstream forks (pull from upstream into managed repos).
fsa_can_sync_forks() {
  fsa_node_detect
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;
    downstream-fork) return 0 ;;
    mirror)          return 1 ;;
  esac
  return 1
}

# Run translation workflows.
fsa_can_translate() {
  fsa_node_detect
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;
    downstream-fork) return 0 ;;
    mirror)          return 1 ;;
  esac
  return 1
}

# Push template files to consumer repos.
fsa_can_manage_templates() {
  fsa_node_detect
  case "${FSA_NODE_POSITION}" in
    source)          return 0 ;;
    downstream-fork) return 0 ;;
    mirror)          return 1 ;;
  esac
  return 1
}

# fsa_node_summary: print a human-readable summary of the detected identity.
fsa_node_summary() {
  fsa_node_detect
  echo "[fsa-node] position=${FSA_NODE_POSITION} owner=${FSA_NODE_OWNER} upstream=${FSA_UPSTREAM_OWNER:-none} depth=${FSA_CHAIN_DEPTH}" >&2
  echo "[fsa-node] capabilities:" >&2
  local caps=()
  fsa_can_mirror_to_github  && caps+=("mirror-to-github")
  fsa_can_mirror_to_gitlab  && caps+=("mirror-to-gitlab")
  fsa_can_update_readmes    && caps+=("update-readmes")
  fsa_can_inject_badges     && caps+=("inject-badges")
  fsa_can_sync_forks        && caps+=("sync-forks")
  fsa_can_translate         && caps+=("translate")
  fsa_can_manage_templates  && caps+=("manage-templates")
  echo "[fsa-node]   ${caps[*]:-none}" >&2
}
