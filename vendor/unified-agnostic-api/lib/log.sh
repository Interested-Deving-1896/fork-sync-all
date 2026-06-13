#!/usr/bin/env bash
# lib/log.sh — shared logging helpers for unified-agnostic-api
#
# Source this file in every script. All output goes to stderr so that
# scripts called inside $(...) captures don't corrupt their stdout return value.
#
# Usage:
#   source lib/log.sh
#   info "starting adapter"
#   warn "rate limit low"
#   error "adapter not found"
#   debug "raw response: $body"

# Guard against double-sourcing
[[ -n "${_UAA_LOG_LOADED:-}" ]] && return 0
_UAA_LOG_LOADED=1

UAA_LOG="${UAA_LOG:-info}"

_log_level_num() {
  case "$1" in
    debug) echo 0 ;;
    info)  echo 1 ;;
    warn)  echo 2 ;;
    error) echo 3 ;;
    *)     echo 1 ;;
  esac
}

_uaa_log() {
  local level="$1"; shift
  local current_num
  current_num=$(_log_level_num "$UAA_LOG")
  local msg_num
  msg_num=$(_log_level_num "$level")
  [[ "$msg_num" -lt "$current_num" ]] && return 0
  local ts
  ts="$(date -u '+%H:%M:%S')"
  echo "[$ts] [${level^^}] $*" >&2
}

debug() { _uaa_log debug "$*"; }
info()  { _uaa_log info  "$*"; }
warn()  { _uaa_log warn  "$*"; }
error() { _uaa_log error "$*"; }
