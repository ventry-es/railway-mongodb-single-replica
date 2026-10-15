#!/usr/bin/env bash
#
# End-to-end checks against a real single-node replica set.
#
# Most of these reproduce a way a MongoDB deployment is known to lose — or
# appear to lose — its data on a platform that redeploys containers freely.
# They are the reason the entrypoint does what it does, so they run in CI on
# every change.
#
#   ./tests/e2e.sh          run everything
#   ./tests/e2e.sh rename   run a single scenario
#
# Scenarios: bootstrap features idempotency keyfile password setname rename volume durability

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly NODE_IMAGE="railway-mongodb-single-replica:test"
readonly NODE=mongodb
readonly REPLICA_SET=rs0

# The rename scenario needs a name that can stop resolving, which a compose
# service name never does, so it runs its own container on its own network.
readonly RENAME_CONTAINER=e2e-rename
readonly RENAME_NETWORK=e2e-rename
readonly RENAME_VOLUME=e2e-rename-data

ROOT_USER="root"
ROOT_PASSWORD="localdevpassword"
SET_NAME="$REPLICA_SET"
failures=0

# ---------------------------------------------------------------- reporting

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
pass() { printf '    \033[32mPASS\033[0m %s\n' "$*"; }
fail() {
  printf '    \033[31mFAIL\033[0m %s\n' "$*"
  failures=$((failures + 1))
}

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$what"
  else
    fail "$what (expected '${expected}', got '${actual}')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$what"
  else
    fail "$what (output did not contain '${needle}')"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$what"
  else
    fail "$what (output contained '${needle}')"
  fi
}

# ------------------------------------------------------------------ helpers

compose() { docker compose "$@"; }

# Connects with replicaSet= exactly as an application would, so every check
# also proves that the host in the replica set configuration resolves.
mongo_eval() {
  compose exec -T "$NODE" mongosh --quiet \
    "mongodb://${NODE}:27017/?replicaSet=${REPLICA_SET}&authSource=admin&serverSelectionTimeoutMS=5000" \
    --username "$ROOT_USER" --password "$ROOT_PASSWORD" \
    --eval "$1" 2>/dev/null | tr -d '\r' | tail -n 1
}

in_container() {
  compose exec -T "$NODE" sh -c "$1" 2>/dev/null | tr -d '\r' | tail -n 1
}

wait_until() {
  local timeout="$1" description="$2"
  shift 2
  local deadline=$(($(date +%s) + timeout))

  until "$@" >/dev/null 2>&1; do
    if (($(date +%s) >= deadline)); then
      fail "timed out after ${timeout}s waiting for ${description}"
      return 1
    fi
    sleep 2
  done
  return 0
}

# A redeploy, as far as the node can tell: a new container on the same volume.
redeploy() {
  compose up --detach --force-recreate --wait "$NODE" >/dev/null
}

_is_primary() {
  [[ "$(mongo_eval 'print(db.hello().isWritablePrimary === true)')" == "true" ]]
}

_ticket_count_is() {
  local expected="$1" id="$2" actual
  actual="$(mongo_eval \
    "const d = db.getSiblingDB(\"events\").tickets.findOne({ _id: \"${id}\" }); print(d ? d.sold : \"\")")"
  [[ "$actual" == "$expected" ]]
}

_password_authenticates() {
  compose exec -T "$NODE" mongosh --quiet \
    --username "$ROOT_USER" --password "$ROOT_PASSWORD" --authenticationDatabase admin \
    --eval 'quit(db.adminCommand({ ping: 1 }).ok === 1 ? 0 : 1)'
}

# Recreated from scratch so a previous run cannot influence this one.
write_env() {
  cat >.env <<EOF
MONGO_REPLICA_SET_NAME=${SET_NAME}
MONGO_INITDB_ROOT_USERNAME=${ROOT_USER}
MONGO_INITDB_ROOT_PASSWORD=${ROOT_PASSWORD}
EOF
}

remove_rename_fixture() {
  docker rm --force "$RENAME_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$RENAME_NETWORK" >/dev/null 2>&1 || true
  docker volume rm "$RENAME_VOLUME" >/dev/null 2>&1 || true
}

setup() {
  step "Building images and starting a clean node"
  write_env

  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  remove_rename_fixture
  compose build --quiet
  docker build --quiet --tag "$NODE_IMAGE" ./mongo >/dev/null
  compose up --detach --wait "$NODE"
  info "node is up"
}

teardown() {
  step "Cleaning up"
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  remove_rename_fixture
  rm -f .env
}

# ---------------------------------------------------------------- scenarios

# A fresh deployment has to become a working replica set on its own, with
# nothing configured by hand.
scenario_bootstrap() {
  step "bootstrap — a fresh deployment becomes a one-member replica set"

  wait_until 90 "the node to become PRIMARY" _is_primary || return
  pass "the node is PRIMARY"
  assert_eq "1" "$(mongo_eval 'print(rs.conf().members.length)')" "the set has exactly one member"
  assert_eq "${NODE}:27017" "$(mongo_eval 'print(rs.conf().members[0].host)')" \
    "the member is registered under its advertised host"

  # Where the unusual dbPath earns its keep: the official image declares
  # VOLUME /data/db, so Docker shadows that path with an anonymous volume. The
  # database has to be in the volume we actually mounted, not in that one.
  assert_eq "yes" "$(in_container '[ -f /data/mongodb/WiredTiger ] && echo yes || echo no')" \
    "the database files are inside the mounted volume"

  # And those shadowed paths still have to exist, because the official
  # entrypoint chowns them under `set -e` before starting mongod. Railway
  # ignores VOLUME declarations, so nothing creates them for us there.
  assert_eq "yes" "$(in_container '[ -d /data/db ] && [ -d /data/configdb ] && echo yes || echo no')" \
    "the paths the official entrypoint expects exist"

  assert_eq "400 mongodb" "$(in_container 'stat -c "%a %U" /data/state/keyfile')" \
    "the keyfile was generated on the volume, readable only by mongod"
  assert_eq "${NODE}:27017" "$(in_container 'cat /data/state/member-host')" \
    "the registered host is remembered on the volume"
}

# The reason to run a replica set of one at all: these fail on a standalone.
scenario_features() {
  step "features — transactions and change streams work"

  assert_eq "1" "$(mongo_eval '
    const session = db.getMongo().startSession();
    session.startTransaction();
    session.getDatabase("events").tickets.insertOne({ _id: "tx", sold: 1 });
    session.commitTransaction();
    print(db.getSiblingDB("events").tickets.countDocuments({ _id: "tx" }))')" \
    "a multi-document transaction commits"

  assert_eq "insert stream" "$(mongo_eval '
    const stream = db.getSiblingDB("events").tickets.watch();
    db.getSiblingDB("events").tickets.insertOne({ _id: "stream" });
    let event = null;
    for (let i = 0; i < 50 && !event; i++) {
      event = stream.tryNext();
      if (!event) sleep(100);
    }
    print(event ? event.operationType + " " + event.documentKey._id : "none")')" \
    "a change stream sees the insert"
}

# Booting again must change nothing. If it did, every deploy would churn the
# replica set configuration.
scenario_idempotency() {
  step "idempotency — a redeploy leaves the replica set untouched"

  local before after
  before="$(mongo_eval 'print(rs.conf().version)')"
  redeploy
  wait_until 90 "the node to become PRIMARY" _is_primary || return
  after="$(mongo_eval 'print(rs.conf().version)')"

  assert_contains "$(compose logs "$NODE" 2>&1)" "already initiated as ${NODE}:27017" \
    "the node reports the set as already initiated"
  assert_eq "$before" "$after" "the replica set configuration version is unchanged"
}

# There is no MONGO_KEYFILE to regenerate, which is the point — but the key
# the node made for itself must survive a redeploy byte for byte.
scenario_keyfile() {
  step "keyfile — the generated key survives a redeploy unchanged"

  local before after
  before="$(in_container 'sha256sum /data/state/keyfile | cut -c1-16')"
  redeploy
  wait_until 90 "the node to become PRIMARY" _is_primary || return
  after="$(in_container 'sha256sum /data/state/keyfile | cut -c1-16')"

  assert_eq "$before" "$after" "the keyfile is the one generated on first boot"
  assert_contains "$(compose logs "$NODE" 2>&1)" "Keyfile already present" "the node reuses it"
}

# The root password only takes effect on first boot, so a regenerated one must
# be rotated rather than ignored.
scenario_password() {
  step "password — a changed MONGO_INITDB_ROOT_PASSWORD is rotated automatically"

  ROOT_PASSWORD="rotated-$(date +%s)"
  write_env
  redeploy

  wait_until 120 "the new password to authenticate" _password_authenticates || return
  pass "the new password authenticates"
  assert_contains "$(compose logs "$NODE" 2>&1)" "Root password rotated" "the node reports the rotation"

  # A second boot with the same value must not try to rotate again.
  redeploy
  wait_until 90 "the node to become PRIMARY" _is_primary || return
  assert_contains "$(compose logs "$NODE" 2>&1)" "Root password matches the value this database was provisioned with" \
    "the next boot finds nothing to rotate"
}

# A replica set cannot be renamed. A changed variable must not be able to take
# the database down with it.
scenario_setname() {
  step "setname — a changed MONGO_REPLICA_SET_NAME cannot strand the database"

  SET_NAME="renamed"
  write_env
  redeploy

  # mongo_eval still asks for rs0: that is the set the node must keep serving.
  wait_until 90 "the node to become PRIMARY as ${REPLICA_SET}" _is_primary || return
  pass "the node is still PRIMARY of '${REPLICA_SET}'"
  assert_contains "$(compose logs "$NODE" 2>&1)" "a replica set cannot be renamed" \
    "the node explains why it ignored the new name"

  SET_NAME="$REPLICA_SET"
  write_env
  redeploy
  wait_until 90 "the node to become PRIMARY" _is_primary || return
}

_rename_run() {
  local host="$1"
  docker rm --force "$RENAME_CONTAINER" >/dev/null 2>&1 || true
  docker run --detach --name "$RENAME_CONTAINER" \
    --network "$RENAME_NETWORK" --network-alias "$host" \
    -e MONGO_REPLICA_SET_NAME="$REPLICA_SET" \
    -e MONGO_INITDB_ROOT_USERNAME="$ROOT_USER" \
    -e MONGO_INITDB_ROOT_PASSWORD="$ROOT_PASSWORD" \
    -e MONGO_ADVERTISED_HOST="$host" \
    -v "${RENAME_VOLUME}:/data" \
    "$NODE_IMAGE" >/dev/null
}

_rename_eval() {
  local host="$1" script="$2"
  docker exec "$RENAME_CONTAINER" mongosh --quiet \
    "mongodb://${host}:27017/?replicaSet=${REPLICA_SET}&authSource=admin&serverSelectionTimeoutMS=5000" \
    --username "$ROOT_USER" --password "$ROOT_PASSWORD" \
    --eval "$script" 2>/dev/null | tr -d '\r' | tail -n 1
}

_rename_is_primary() {
  [[ "$(_rename_eval "$1" 'print(db.hello().isWritablePrimary === true)')" == "true" ]]
}

# Renaming the service changes its private domain. The old name stops
# resolving, the node no longer recognises itself in its own configuration, and
# without intervention it never becomes PRIMARY again.
scenario_rename() {
  step "rename — the database follows a renamed service"

  docker network create "$RENAME_NETWORK" >/dev/null
  docker volume create "$RENAME_VOLUME" >/dev/null

  _rename_run mongo-old
  wait_until 90 "the node to become PRIMARY as mongo-old" _rename_is_primary mongo-old || return
  _rename_eval mongo-old \
    'db.getSiblingDB("events").tickets.insertOne({ _id: "renamed", sold: 7 }, { writeConcern: { w: "majority" } })' >/dev/null
  info "wrote a document as mongo-old, then recreating the node as mongo-new"

  _rename_run mongo-new
  wait_until 120 "the node to become PRIMARY as mongo-new" _rename_is_primary mongo-new || return
  pass "the node is PRIMARY under its new name"

  assert_eq "mongo-new:27017" "$(_rename_eval mongo-new 'print(rs.conf().members[0].host)')" \
    "the member is registered under the new name"
  assert_eq "7" "$(_rename_eval mongo-new 'print(db.getSiblingDB("events").tickets.findOne({ _id: "renamed" }).sold)')" \
    "the document written before the rename is still there"
  assert_contains "$(docker logs "$RENAME_CONTAINER" 2>&1)" "Member host rewritten from mongo-old:27017 to mongo-new:27017" \
    "the node reports the move"

  # Once moved, the next boot must start straight away, without a standalone.
  _rename_run mongo-new
  wait_until 90 "the node to become PRIMARY again" _rename_is_primary mongo-new || return
  assert_not_contains "$(docker logs "$RENAME_CONTAINER" 2>&1)" "Rewriting the member's host" \
    "the next boot does not rewrite it again"

  remove_rename_fixture
}

# Without a volume, mongod would write to storage the platform throws away.
scenario_volume() {
  step "volume — a node without persistent storage refuses to start"

  local output status=0
  output="$(docker run --rm \
    -e MONGO_REPLICA_SET_NAME="$REPLICA_SET" \
    -e MONGO_INITDB_ROOT_USERNAME="$ROOT_USER" \
    -e MONGO_INITDB_ROOT_PASSWORD="$ROOT_PASSWORD" \
    "$NODE_IMAGE" 2>&1)" || status=$?

  assert_eq "1" "$status" "the container exits with an error"
  assert_contains "$output" "No volume is mounted at /data" "the reason is stated explicitly"
}

# A redeploy recreates the container. The data must not care.
scenario_durability() {
  step "durability — data survives recreating the container"

  wait_until 90 "the node to become PRIMARY" _is_primary || return
  mongo_eval \
    'db.getSiblingDB("events").tickets.insertOne({ _id: "durable", sold: 42 }, { writeConcern: { w: "majority" } })' >/dev/null

  redeploy
  wait_until 90 "the node to become PRIMARY after the redeploy" _is_primary || return

  wait_until 60 "the document to be readable after the redeploy" \
    _ticket_count_is 42 durable || return
  pass "the document written before the redeploy is still there"
}

# ---------------------------------------------------------------------- main

main() {
  local scenarios=("$@")
  if ((${#scenarios[@]} == 0)); then
    scenarios=(bootstrap features idempotency keyfile password setname rename volume durability)
  fi

  trap teardown EXIT
  setup

  local scenario
  for scenario in "${scenarios[@]}"; do
    "scenario_${scenario}"
  done

  step "Result"
  if ((failures == 0)); then
    printf '    \033[32mall scenarios passed\033[0m\n'
  else
    printf '    \033[31m%d check(s) failed\033[0m\n' "$failures"
  fi
  return "$((failures > 0 ? 1 : 0))"
}

main "$@"
