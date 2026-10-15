# shellcheck shell=bash
#
# Logging, environment validation and small helpers shared by the entrypoint.

LOG_SCOPE="${LOG_SCOPE:-mongo}"

_log() {
  local level="$1"
  shift
  printf '%s [%s] %-5s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_SCOPE" "$level" "$*"
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@" >&2; }

# Boxed output for the handful of messages an operator must not miss in a wall
# of mongod logs.
log_box() {
  local level="$1"
  shift
  _log "$level" "+------------------------------------------------------------------+"
  local line
  for line in "$@"; do
    _log "$level" "| $line"
  done
  _log "$level" "+------------------------------------------------------------------+"
}

# Misconfiguration we must not paper over: stop before mongod touches anything.
die() {
  log_box ERROR "$@"
  exit 1
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      die "Required variable ${name} is not set." \
        "Set it on this service in the Railway dashboard (Variables tab)," \
        "or see docs/TEMPLATE.md for the full variable matrix."
    fi
  done
}

# Short, non-reversible identifier for a secret, so the same value can be
# recognised across deploys without ever printing it.
fingerprint() {
  printf '%s' "$1" | sha256sum | cut -c1-8
}

# Everything under /data/state is written whole or not at all: a half-written
# file there would be trusted on the next boot.
write_state_file() {
  local path="$1" value="$2"
  printf '%s' "$value" >"${path}.tmp"
  chmod 0400 "${path}.tmp"
  mv -f "${path}.tmp" "$path"
}

# Render a shell string as a JavaScript string literal. Credentials reach
# mongosh through --eval, so they must not be able to break out of their quotes.
js_string() {
  local escaped="$1"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '"%s"' "$escaped"
}

# Reject credentials that cannot be embedded safely or that MongoDB itself
# would mangle. Catching this at boot beats debugging an auth failure later.
assert_single_line() {
  local name="$1" value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
    die "${name} contains a newline or tab character." \
      "Use a value without whitespace — regenerate it with \${{secret(48)}}."
  fi
}

# Same probe the deployment uses everywhere: does the local mongod answer, and
# is it the real replica set member rather than one of the temporary
# standalones — the official entrypoint's, while it creates the root user, or
# ours, while it moves a renamed member (lib/replicaset.sh)?
mongo_eval_local() {
  mongosh --quiet --host 127.0.0.1 --port "$MONGO_PORT" --eval "$1" 2>/dev/null
}

mongo_eval_local_auth() {
  local password="$1" script="$2"
  mongosh --quiet --host 127.0.0.1 --port "$MONGO_PORT" \
    --username "$MONGO_INITDB_ROOT_USERNAME" \
    --password "$password" \
    --authenticationDatabase admin \
    --eval "$script" 2>&1
}

# Blocks until `hello()` reports a replica set member. Returns 1 on timeout so
# callers can log something useful instead of hanging forever.
wait_for_replica_set_member() {
  local timeout="$1" deadline
  deadline=$(($(date +%s) + timeout))

  while [[ $(date +%s) -lt $deadline ]]; do
    # `isreplicaset` is true for an uninitiated member; `setName` appears once
    # the member belongs to a configured set. A standalone reports neither.
    if [[ $(mongo_eval_local 'const h = db.hello(); print(h.isreplicaset === true || Boolean(h.setName))') == "true" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

node_is_writable_primary() {
  [[ $(mongo_eval_local 'const h = db.hello(); print(Boolean(h.setName) && h.isWritablePrimary === true)') == "true" ]]
}

wait_for_writable_primary() {
  local timeout="$1" deadline
  deadline=$(($(date +%s) + timeout))

  while [[ $(date +%s) -lt $deadline ]]; do
    if node_is_writable_primary; then
      return 0
    fi
    sleep 2
  done
  return 1
}
