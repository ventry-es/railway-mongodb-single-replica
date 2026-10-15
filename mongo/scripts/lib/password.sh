# shellcheck shell=bash
#
# Defence #3 against data loss: the root password the database was actually
# provisioned with is remembered on the volume.
#
# The official mongo entrypoint only creates the root user on the very first
# boot, when the data directory is empty. From then on MONGO_INITDB_ROOT_PASSWORD
# is ignored — so if the template regenerates it, every client is locked out of
# a database that is otherwise perfectly intact. That is the failure people
# mistake for "the deploy wiped my data".
#
# The sentinel file lets us tell the two cases apart and repair the drift:
# the environment stays the source of truth, and the password in the database
# is rotated to match it.

readonly PASSWORD_ROTATION_TIMEOUT_SEC="${MONGO_PASSWORD_ROTATION_TIMEOUT_SEC:-180}"

# Mirrors the check in the official docker-entrypoint.sh: these files only exist
# once mongod has created a database in this directory.
_database_is_initialised() {
  local db_path="$1" marker
  for marker in WiredTiger journal local.0 storage.bson; do
    [[ -e "${db_path}/${marker}" ]] && return 0
  done
  return 1
}

_root_password_works() {
  mongo_eval_local_auth "$1" 'db.adminCommand({ ping: 1 })' >/dev/null 2>&1
}

_change_root_password() {
  local sentinel="$1" old_password="$2" new_password="$3"

  if ! _root_password_works "$old_password"; then
    log_box ERROR \
      "Cannot rotate the root password: neither the persisted value nor the" \
      "value in MONGO_INITDB_ROOT_PASSWORD authenticates." \
      "The data is intact — only the credentials are out of sync." \
      "Recovery steps are in docs/TROUBLESHOOTING.md. Do NOT delete the volume."
    return 0
  fi

  local script
  script="db.getSiblingDB(\"admin\").changeUserPassword($(js_string "$MONGO_INITDB_ROOT_USERNAME"), $(js_string "$new_password"))"

  if mongo_eval_local_auth "$old_password" "$script" >/dev/null; then
    write_state_file "$sentinel" "$new_password"
    log_box INFO \
      "Root password rotated to the value in MONGO_INITDB_ROOT_PASSWORD." \
      "Any client using the previous password must be updated."
  else
    log_box ERROR \
      "changeUserPassword failed. The database keeps the previous password," \
      "which is still available on this node's volume." \
      "See docs/TROUBLESHOOTING.md — do NOT delete the volume."
  fi
}

# Runs detached from the boot path. It must never take the deployment down:
# a database that is up with the wrong password is still recoverable, a
# database that refuses to start is not.
#
# changeUserPassword is a write, so it has to wait until this node has elected
# itself PRIMARY — a few seconds after mongod starts. Each turn of the loop
# also checks whether the new password already works: if someone changed it by
# hand to the same value, there is nothing left to do but catch the sentinel up.
_rotate_root_password() {
  local sentinel="$1" old_password="$2" new_password="$3" deadline
  deadline=$(($(date +%s) + PASSWORD_ROTATION_TIMEOUT_SEC))

  while [[ $(date +%s) -lt $deadline ]]; do
    if _root_password_works "$new_password"; then
      write_state_file "$sentinel" "$new_password"
      log_info "Root password already matches the environment; sentinel updated."
      return 0
    fi

    if node_is_writable_primary; then
      _change_root_password "$sentinel" "$old_password" "$new_password"
      return 0
    fi

    sleep 3
  done

  log_box WARN \
    "Root password rotation did not complete within ${PASSWORD_ROTATION_TIMEOUT_SEC}s." \
    "This node never became PRIMARY, so the password could not be changed." \
    "Clients should keep using the previously provisioned password; the next" \
    "boot tries again. Nothing was changed and no data is affected."
}

# Warns — in the background — when adopted credentials turn out to be wrong,
# so the cause shows up in the logs instead of as a mystery auth error later.
_verify_root_password() {
  local password="$1"

  wait_for_replica_set_member "$PASSWORD_ROTATION_TIMEOUT_SEC" || return 0

  if ! _root_password_works "$password"; then
    log_box WARN \
      "MONGO_INITDB_ROOT_PASSWORD does not authenticate against this database." \
      "The data is intact; the credentials simply do not match what the" \
      "database was provisioned with. See docs/TROUBLESHOOTING.md."
  fi
}

reconcile_root_password() {
  local sentinel="$1" db_path="$2" env_password="$MONGO_INITDB_ROOT_PASSWORD"

  if [[ ! -f "$sentinel" ]]; then
    if _database_is_initialised "$db_path"; then
      # An existing database from before this template recorded the sentinel.
      # We cannot know what it was provisioned with, so adopt the environment
      # value and verify it rather than guessing at a rotation.
      log_warn "No password sentinel found for an existing database; adopting the current environment value."
      _verify_root_password "$env_password" &
    else
      log_info "First boot: the official entrypoint will create user '${MONGO_INITDB_ROOT_USERNAME}'."
    fi
    write_state_file "$sentinel" "$env_password"
    return 0
  fi

  local persisted
  persisted="$(cat "$sentinel")"

  if [[ "$persisted" == "$env_password" ]]; then
    log_info "Root password matches the value this database was provisioned with."
    return 0
  fi

  if [[ "${MONGO_PASSWORD_ROTATION:-auto}" != "auto" ]]; then
    log_box WARN \
      "MONGO_INITDB_ROOT_PASSWORD differs from the provisioned password, but" \
      "MONGO_PASSWORD_ROTATION is not 'auto' so nothing will be changed." \
      "Clients must keep using the previously provisioned password."
    return 0
  fi

  log_info "Root password drift detected; scheduling rotation once this node can accept writes."
  _rotate_root_password "$sentinel" "$persisted" "$env_password" &
}
