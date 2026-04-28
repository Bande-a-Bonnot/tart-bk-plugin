#!/usr/bin/env bash
# Local no-VM check for the staging invariant: generated env/command files may
# contain short-lived job/session tokens but must not contain long-lived secret
# markers or the Doppler token value.
set -euo pipefail

tmp="$(mktemp -d -t foundry-plugin-staging.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

export BUILDKITE_PLUGIN_TART_FORWARD_ENV_0=AGENT_SESSION_ID
export BUILDKITE_PLUGIN_TART_FORWARD_ENV_1=FOUNDRY_PROMPT_PULL_TOKEN
export BUILDKITE_PLUGIN_TART_FORWARD_ENV_2=BUILDKITE_AGENT_ACCESS_TOKEN
export AGENT_SESSION_ID='sess with spaces'
export FOUNDRY_PROMPT_PULL_TOKEN='short-lived-pull-token'
export BUILDKITE_AGENT_ACCESS_TOKEN='short-lived-bk-token'
export BUILDKITE_COMMAND='echo ok'

shell_quote() { python3 -c 'import shlex,sys; sys.stdout.write(shlex.quote(sys.stdin.read()))'; }
plugin_array() {
  local key="$1" i=0 v
  while :; do
    v="BUILDKITE_PLUGIN_TART_${key}_${i}"
    [ -n "${!v:-}" ] || break
    printf '%s\n' "${!v}"
    i=$((i + 1))
  done
}

ENV_FILE="$tmp/.env.sh"
CMD_FILE="$tmp/.cmd.sh"
{
  echo '# generated test env'
  while IFS= read -r key; do
    value="${!key:-}"
    quoted="$(printf '%s' "$value" | shell_quote)"
    printf 'export %s=%s\n' "$key" "$quoted"
  done < <(plugin_array FORWARD_ENV)
} >"$ENV_FILE"
cat >"$CMD_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /tmp/scratch/checkout
${BUILDKITE_COMMAND}
EOF

if ! grep -q 'short-lived-pull-token' "$ENV_FILE"; then
  echo 'expected pull token in staged env' >&2
  exit 1
fi
if grep -E 'DOPPLER_TOKEN|PRIVATE_KEY|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|super-secret-doppler' "$ENV_FILE" "$CMD_FILE"; then
  echo 'forbidden secret marker found in staged files' >&2
  exit 1
fi
bash -n "$CMD_FILE"
echo 'ok: staging files exclude long-lived secret markers'
