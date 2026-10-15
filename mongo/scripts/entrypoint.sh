#!/usr/bin/env bash
#
# Entrypoint for the single-node replica set.
#
# Everything that must survive a redeploy lives on the volume, and nothing on
# the volume is ever overwritten from the environment. See docs/ARCHITECTURE.md
# for the reasoning behind each step.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/volume.sh"
source "${SCRIPT_DIR}/lib/keyfile.sh"
source "${SCRIPT_DIR}/lib/password.sh"
source "${SCRIPT_DIR}/lib/replicaset.sh"

# These paths are part of the template's contract with existing deployments.
# Changing them makes Railway attach a new, empty volume and orphan the old
# one, so they are deliberately not configurable.
#
# The database lives in /data/mongodb rather than the conventional /data/db
# because the official image declares `VOLUME /data/db`: with our volume
# attached at /data, a container runtime creates a second, anonymous volume
# over /data/db and the database silently ends up outside the volume we mounted.
readonly DATA_ROOT="/data"
readonly DB_PATH="${DATA_ROOT}/mongodb"
readonly STATE_DIR="${DATA_ROOT}/state"
readonly KEYFILE_PATH="${STATE_DIR}/keyfile"
readonly PASSWORD_SENTINEL="${STATE_DIR}/root-password"
readonly REPLICA_SET_SENTINEL="${STATE_DIR}/replica-set-name"
readonly MEMBER_HOST_SENTINEL="${STATE_DIR}/member-host"

MONGO_PORT="${MONGO_PORT:-27017}"
export MONGO_PORT

prepare_directories() {
  mkdir -p "$DB_PATH" "$STATE_DIR"

  # Nothing is stored in these two, but the official entrypoint runs
  # `find -L /data/configdb /data/db` under `set -e` before it starts mongod.
  # Docker keeps those paths alive through the image's VOLUME declarations;
  # Railway ignores VOLUME, so with our volume mounted at /data they are simply
  # gone, find exits non-zero, and the container restarts before mongod ever
  # runs. Creating them costs nothing and keeps both runtimes happy.
  mkdir -p "${DATA_ROOT}/db" "${DATA_ROOT}/configdb"

  if [[ "$(id -u)" -eq 0 ]]; then
    chown mongodb:mongodb "$DATA_ROOT" "$STATE_DIR" "${DATA_ROOT}/db" "${DATA_ROOT}/configdb"
    chmod 0700 "$STATE_DIR"
    # The official entrypoint only fixes ownership under /data/db, so a custom
    # dbPath is ours to look after. Touching just the files that need it keeps
    # this from becoming a full pass over a large volume on every boot.
    find -L "$DB_PATH" \! -user mongodb -exec chown mongodb:mongodb '{}' +
  else
    log_warn "Not running as root; skipping ownership fixes on ${DATA_ROOT}."
    log_warn "If mongod fails to read its keyfile, set RAILWAY_RUN_UID=0 on this service."
  fi
}

# The hostname clients will be told to use. It is written into the replica set
# configuration, so there is no useful fallback: the container's own hostname
# is a container id that nothing else can resolve, and a driver connecting with
# replicaSet= follows whatever name the configuration holds. Refusing to guess
# is the cheaper failure.
advertised_host() {
  local host="${MONGO_ADVERTISED_HOST:-${RAILWAY_PRIVATE_DOMAIN:-}}"

  if [[ -z "$host" ]]; then
    die "Cannot determine the hostname to advertise to clients." \
      "On Railway this comes from RAILWAY_PRIVATE_DOMAIN and needs no setup." \
      "Anywhere else, set MONGO_ADVERTISED_HOST to the name clients use to" \
      "reach this node."
  fi

  if [[ ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    die "'${host}' is not a valid hostname to advertise." \
      "Set MONGO_ADVERTISED_HOST to a plain hostname, without a port."
  fi

  printf '%s' "$host"
}

build_mongod_args() {
  local -n args_ref="$1"

  args_ref=(
    mongod
    --replSet "$REPLICA_SET_NAME"
    --keyFile "$KEYFILE_PATH"
    --dbpath "$DB_PATH"
    --port "$MONGO_PORT"
    # Railway's private network is IPv6-native; older environments are IPv6-only.
    --bind_ip_all
    --ipv6
  )

  # mongod sizes its cache from the host's memory, which on a shared host is far
  # more than the container is allowed to use. Cap it explicitly when the plan
  # is known.
  if [[ -n "${MONGO_WIREDTIGER_CACHE_GB:-}" ]]; then
    args_ref+=(--wiredTigerCacheSizeGB "$MONGO_WIREDTIGER_CACHE_GB")
  fi

  if [[ -n "${MONGO_OPLOG_SIZE_MB:-}" ]]; then
    args_ref+=(--oplogSize "$MONGO_OPLOG_SIZE_MB")
  fi

  if [[ -n "${MONGO_EXTRA_FLAGS:-}" ]]; then
    local extra
    read -ra extra <<<"$MONGO_EXTRA_FLAGS"
    args_ref+=("${extra[@]}")
  fi
}

main() {
  log_info "Starting MongoDB single-node replica set '${MONGO_REPLICA_SET_NAME:-<unset>}'."

  require_env MONGO_REPLICA_SET_NAME MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD
  assert_single_line MONGO_INITDB_ROOT_USERNAME "$MONGO_INITDB_ROOT_USERNAME"
  assert_single_line MONGO_INITDB_ROOT_PASSWORD "$MONGO_INITDB_ROOT_PASSWORD"
  [[ "$MONGO_REPLICA_SET_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] ||
    die "MONGO_REPLICA_SET_NAME may only contain letters, digits, '.', '_' and '-'."

  assert_persistent_storage "$DATA_ROOT"
  prepare_directories
  ensure_keyfile "$KEYFILE_PATH"
  pin_replica_set_name "$REPLICA_SET_SENTINEL"

  local host self_host
  host="$(advertised_host)"
  self_host="${host}:${MONGO_PORT}"

  wait_for_own_name "$host"
  adopt_renamed_host "$MEMBER_HOST_SENTINEL" "$DB_PATH" "$self_host"

  # This starts background tasks, so it comes after the standalone above has
  # stopped: they must only ever talk to the real replica set member.
  reconcile_root_password "$PASSWORD_SENTINEL" "$DB_PATH"

  # The sentinel holds the password the database currently answers to; a
  # rotation may still be in flight at this point.
  local provisioned_password
  provisioned_password="$(cat "$PASSWORD_SENTINEL")"
  ensure_replica_set "$self_host" "$provisioned_password" "$MEMBER_HOST_SENTINEL" &

  local mongod_args
  build_mongod_args mongod_args

  log_info "Handing over to mongod: ${mongod_args[*]}"
  # exec keeps mongod as PID 1 so Railway's SIGTERM reaches it directly and the
  # node shuts down cleanly instead of being killed mid-write.
  exec docker-entrypoint.sh "${mongod_args[@]}"
}

main "$@"
