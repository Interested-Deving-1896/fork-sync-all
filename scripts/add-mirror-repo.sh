#!/usr/bin/env bash
# Compatibility entry point retained for the existing Add Mirror Repo workflow.
# The Python provisioner creates real GitHub forks in order:
# canonical Interested-Deving-1896 repo -> OSP fork -> OOC fork.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${script_dir}/add_mirror_repo.py" "${REPO_URL:?REPO_URL is required}"
