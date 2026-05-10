#!/usr/bin/env bash
# Local no-VM checks for plugin staging invariants: generated env/command files
# may contain explicit short-lived job/session tokens but must reject long-lived
# secret-shaped names and private-key material.
set -euo pipefail

tmp="$(mktemp -d -t foundry-plugin-staging.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

shell_quote() { python3 -c 'import shlex,sys; sys.stdout.write(shlex.quote(sys.stdin.read()))'; }

is_forbidden_forward_env() {
  local key="$1"
  case "${key}" in
    BUILDKITE_AGENT_ACCESS_TOKEN|FOUNDRY_PROMPT_PULL_TOKEN)
      return 1
      ;;
    DOPPLER_TOKEN|BUILDKITE_API_ACCESS_TOKEN|*_SECRET|*_PRIVATE_KEY|*_CLIENT_SECRET|*_ACCESS_KEY|*_PASSWORD|*_ACCESS_TOKEN)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_staged_files_for_forbidden_markers() {
  python3 - "$@" <<'PY'
import re
import sys
from pathlib import Path

allowed = {"BUILDKITE_AGENT_ACCESS_TOKEN", "FOUNDRY_PROMPT_PULL_TOKEN"}
exact = {"DOPPLER_TOKEN", "BUILDKITE_API_ACCESS_TOKEN"}
suffixes = ("_SECRET", "_PRIVATE_KEY", "_CLIENT_SECRET", "_ACCESS_KEY", "_PASSWORD", "_ACCESS_TOKEN")
assignment = re.compile(r"(?:^|[\s;])(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=")
pem = re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY")

def forbidden_name(name: str) -> bool:
    if name in allowed:
        return False
    return name in exact or any(name.endswith(suffix) for suffix in suffixes)

bad = []
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    text = path.read_text(errors="replace")
    if pem.search(text):
        bad.append(f"{path}: PEM private-key marker")
    for line_no, line in enumerate(text.splitlines(), 1):
        for match in assignment.finditer(line):
            name = match.group(1)
            if forbidden_name(name):
                bad.append(f"{path}:{line_no}: forbidden env assignment {name}")
if bad:
    for item in bad:
        print(item, file=sys.stderr)
    sys.exit(1)
PY
}

write_staged_files() {
  local env_file="$1"
  local cmd_file="$2"
  shift 2
  {
    echo '# generated test env'
    echo 'export FOUNDRY_VM_ISOLATED=1'
    for key in "$@"; do
      case "${key}" in
        *[!A-Za-z0-9_]*|[0-9]*) echo "invalid env name: ${key}" >&2; return 1 ;;
      esac
      if is_forbidden_forward_env "${key}"; then
        echo "forbidden forward env name: ${key}" >&2
        return 1
      fi
      value="${!key:-}"
      quoted="$(printf '%s' "$value" | shell_quote)"
      printf 'export %s=%s\n' "$key" "$quoted"
    done
  } >"$env_file"
  cat >"$cmd_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd /tmp/scratch/checkout
${BUILDKITE_COMMAND:-echo ok}
EOF
}

assert_reject_forward_env() {
  local key="$1"
  local env_file="$tmp/${key}.env.sh"
  local cmd_file="$tmp/${key}.cmd.sh"
  if write_staged_files "$env_file" "$cmd_file" "$key" >/dev/null 2>&1; then
    echo "expected forward_env ${key} to be rejected" >&2
    exit 1
  fi
}

assert_reject_staged_marker() {
  local label="$1"
  local marker="$2"
  local env_file="$tmp/${label}.env.sh"
  local cmd_file="$tmp/${label}.cmd.sh"
  printf '# test\n%s\n' "$marker" >"$env_file"
  printf '#!/usr/bin/env bash\necho ok\n' >"$cmd_file"
  if check_staged_files_for_forbidden_markers "$env_file" "$cmd_file" >/dev/null 2>&1; then
    echo "expected staged marker to be rejected: ${marker}" >&2
    exit 1
  fi
}

export AGENT_SESSION_ID='sess with spaces'
export FOUNDRY_PROMPT_PULL_TOKEN='short-lived-pull-token'
export BUILDKITE_AGENT_ACCESS_TOKEN='short-lived-bk-token'
export BUILDKITE_COMMAND='echo ok'

ENV_FILE="$tmp/.env.sh"
CMD_FILE="$tmp/.cmd.sh"
write_staged_files \
  "$ENV_FILE" \
  "$CMD_FILE" \
  AGENT_SESSION_ID \
  FOUNDRY_PROMPT_PULL_TOKEN \
  BUILDKITE_AGENT_ACCESS_TOKEN

if ! grep -q 'short-lived-pull-token' "$ENV_FILE"; then
  echo 'expected pull token in staged env' >&2
  exit 1
fi
check_staged_files_for_forbidden_markers "$ENV_FILE" "$CMD_FILE"
bash -n "$CMD_FILE"

for key in \
  DOPPLER_TOKEN \
  FOUNDRY_GITHUB_APP_PRIVATE_KEY \
  LINEAR_FOUNDRY_AGENT_CLIENT_SECRET \
  OAUTH_STATE_SECRET \
  BUILDKITE_API_ACCESS_TOKEN \
  AWS_ACCESS_KEY \
  DATABASE_PASSWORD \
  LINEAR_FOUNDRY_AGENT_ACCESS_TOKEN; do
  assert_reject_forward_env "$key"
done

assert_reject_staged_marker doppler 'export DOPPLER_TOKEN=super-secret-doppler'
assert_reject_staged_marker private_key 'export FOUNDRY_GITHUB_APP_PRIVATE_KEY=abc'
assert_reject_staged_marker client_secret 'export LINEAR_FOUNDRY_AGENT_CLIENT_SECRET=abc'
assert_reject_staged_marker generic_secret 'export OAUTH_STATE_SECRET=abc'
assert_reject_staged_marker buildkite_api 'export BUILDKITE_API_ACCESS_TOKEN=bkua_secret'
assert_reject_staged_marker pem '-----BEGIN PRIVATE KEY-----'
assert_reject_staged_marker rsa_pem '-----BEGIN RSA PRIVATE KEY-----'
assert_reject_staged_marker access_token 'export LINEAR_FOUNDRY_AGENT_ACCESS_TOKEN=lin_secret'

echo 'ok: staging files exclude long-lived secret markers'
