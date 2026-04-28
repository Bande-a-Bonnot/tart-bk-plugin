#!/usr/bin/env bash
# Shared helpers for the Foundry Tart BuildKite plugin.

set -euo pipefail

log() { printf '[foundry:tart-plugin] %s\n' "$*" >&2; }

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

build_id_for_name="${BUILDKITE_BUILD_ID:-${BUILDKITE_JOB_ID:-unknown}}"
VM_NAME="job-$(sanitize_name "${build_id_for_name}")"
STATE_FILE="/tmp/foundry-tart-${VM_NAME}.env"

# BuildKite derives plugin env prefixes from plugin identifiers. During local
# development and depending on the external repo name, either of these may be
# present. Support both so hooks are robust during the repo→external-plugin
# publication step.
plugin_var() {
  local key="$1"
  local v
  for prefix in BUILDKITE_PLUGIN_TART_BK_PLUGIN BUILDKITE_PLUGIN_TART; do
    v="${prefix}_${key}"
    if [ -n "${!v:-}" ]; then
      printf '%s' "${!v}"
      return 0
    fi
  done
  return 1
}

plugin_var_default() {
  local key="$1" default="$2"
  plugin_var "$key" || printf '%s' "$default"
}

plugin_array() {
  local key="$1"
  local i=0 v
  while :; do
    local found=0
    for prefix in BUILDKITE_PLUGIN_TART_BK_PLUGIN BUILDKITE_PLUGIN_TART; do
      v="${prefix}_${key}_${i}"
      if [ -n "${!v:-}" ]; then
        printf '%s\n' "${!v}"
        found=1
        break
      fi
    done
    if [ "$found" = 0 ]; then
      break
    fi
    i=$((i + 1))
  done
}

ssh_opts() {
  cat <<'EOF'
-o UserKnownHostsFile=/dev/null
-o StrictHostKeyChecking=no
-o IdentitiesOnly=yes
-o PreferredAuthentications=password
-o PubkeyAuthentication=no
-o LogLevel=ERROR
EOF
}

write_state() {
  local host_scratch="$1"
  umask 077
  cat >"${STATE_FILE}" <<EOF
VM_NAME=${VM_NAME}
HOST_SCRATCH=${host_scratch}
EOF
}

read_state() {
  if [ -r "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${STATE_FILE}"
  fi
  VM_NAME="${VM_NAME:-job-$(sanitize_name "${build_id_for_name}")}"
}

cleanup_vm_and_scratch() {
  read_state
  if command -v tart >/dev/null 2>&1; then
    tart stop "${VM_NAME}" >/dev/null 2>&1 || true
    tart delete "${VM_NAME}" >/dev/null 2>&1 || true
  fi
  if [ -n "${HOST_SCRATCH:-}" ]; then
    case "${HOST_SCRATCH}" in
      /tmp/foundry-scratch-*|/private/tmp/foundry-scratch-*) rm -rf "${HOST_SCRATCH}" || true ;;
      *) log "refusing to remove unexpected scratch path: ${HOST_SCRATCH}" ;;
    esac
  fi
  rm -f "${STATE_FILE}" || true
}
