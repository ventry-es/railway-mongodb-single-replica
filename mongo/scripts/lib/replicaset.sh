# shellcheck shell=bash
#
# The replica set itself: one member, created once, and kept answering to
# whatever name the service currently has.
#
# Defence #4 against data loss: rs.initiate() runs at most once, ever.
# Re-initiating a configured replica set throws away its identity; on a node
# that merely fails to recognise itself it does worse, and leaves the node
# unusable. So it only runs when local.system.replset is empty — never on the
# strength of a NotYetInitialized error alone, which a renamed node reports too.
#
# Defence #5: renaming the service does not strand the database.
# Defence #6: the replica set name is fixed by the first boot.
# Defence #7: mongod never starts before its own name resolves, and a node
# that started while the name still led to its predecessor is brought back.
#
# Bootstrapping happens inside the node because keyfile authentication is on
# from the first byte, and MongoDB's localhost exception is the only way to
# configure a set before a client can authenticate.

readonly BOOTSTRAP_TIMEOUT_SEC="${MONGO_BOOTSTRAP_TIMEOUT_SEC:-300}"
readonly DNS_TIMEOUT_SEC="${MONGO_DNS_TIMEOUT_SEC:-120}"
readonly DNS_SETTLE_SEC="${MONGO_DNS_SETTLE_SEC:-60}"

# Set by pin_replica_set_name; the name mongod is actually started with.
REPLICA_SET_NAME=""

# ----------------------------------------------------------------- set name

# A replica set cannot be renamed: mongod started with a different --replSet
# than the one stored in its configuration does not recognise itself and never
# becomes PRIMARY. The name is fixed by the first boot of the volume, then, and
# the environment can only seed it — exactly like the keyfile.
pin_replica_set_name() {
  local sentinel="$1" requested="$MONGO_REPLICA_SET_NAME"

  if [[ ! -f "$sentinel" ]]; then
    write_state_file "$sentinel" "$requested"
    REPLICA_SET_NAME="$requested"
    return 0
  fi

  REPLICA_SET_NAME="$(cat "$sentinel")"

  if [[ "$REPLICA_SET_NAME" != "$requested" ]]; then
    log_box WARN \
      "MONGO_REPLICA_SET_NAME is '${requested}', but this database was created" \
      "as replica set '${REPLICA_SET_NAME}', and a replica set cannot be renamed." \
      "The node keeps running as '${REPLICA_SET_NAME}'. Clients connecting with" \
      "replicaSet=${requested} will not find it — set the variable back."
  fi
}

# --------------------------------------------------------------------- DNS

# mongod works out which configured member it is by resolving the hosts in its
# replica set configuration as it starts. If its own name does not resolve at
# that moment it comes up without a valid configuration, and it does not look
# again when the name starts resolving — in a larger set a peer's heartbeat
# would eventually prompt it, but a single member has no peers. Railway's
# private DNS can trail a container's start, so wait for it.
#
# Resolving is not enough, though: on a redeploy Railway's DNS keeps answering
# with the previous container's addresses for a few seconds after the new one
# starts (about nine, observed). mongod that resolves its name in that window
# spends half a minute trying to reach itself at an address nothing answers on
# any more, and settles into REMOVED. So also wait — briefly — for the name to
# resolve to one of this container's own addresses, which is the first thing
# mongod checks and lets it find itself without connecting anywhere.
#
# Behind NAT or a proxy that never happens, so that wait gives up after
# DNS_SETTLE_SEC rather than failing the boot; ensure_replica_set recovers a
# node that started too early anyway (see _rejoin_replica_set).
wait_for_own_name() {
  local host="$1" deadline
  deadline=$(($(date +%s) + DNS_TIMEOUT_SEC))

  if ! getent hosts "$host" >/dev/null; then
    log_info "Waiting for ${host} to resolve before starting mongod ..."

    until getent hosts "$host" >/dev/null; do
      if (($(date +%s) >= deadline)); then
        die "${host} did not resolve within ${DNS_TIMEOUT_SEC}s." \
          "mongod must resolve its own name to recognise itself in the replica" \
          "set; starting now would leave the database without a PRIMARY." \
          "On Railway this is the service's private domain. Anywhere else, check" \
          "MONGO_ADVERTISED_HOST. The service will restart and try again."
      fi
      sleep 1
    done
    log_info "  ${host} resolves."
  fi

  _name_resolves_here "$host" && return 0
  log_info "${host} does not resolve to this container yet; waiting up to ${DNS_SETTLE_SEC}s for DNS to catch up ..."

  deadline=$(($(date +%s) + DNS_SETTLE_SEC))
  until _name_resolves_here "$host"; do
    if (($(date +%s) >= deadline)); then
      log_warn "${host} still does not resolve to this container; starting mongod anyway."
      return 0
    fi
    sleep 1
  done
  log_info "  ${host} now resolves to this container."
}

# Whether any address host resolves to belongs to this container — the same
# test mongod applies first when it looks for itself among its members.
_name_resolves_here() {
  local host="$1" own resolved
  own="$(hostname -I 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')" || return 1
  resolved="$(getent ahosts "$host" 2>/dev/null | awk '{ print $1 }' | sort -u)" || return 1
  [[ -n "$own" && -n "$resolved" ]] || return 1
  grep -Fxq -f <(printf '%s\n' "$own") <<<"$resolved"
}

# --------------------------------------------------------- renamed service

_as_mongodb() {
  if [[ "$(id -u)" -eq 0 ]]; then
    gosu mongodb "$@"
  else
    "$@"
  fi
}

# Leaves the outcome in REWRITE_RESULT rather than printing it, because it may
# have to stop the boot, and `die` inside a command substitution would only
# leave the subshell. One of: rewritten, missing, multi-member, error: <reason>.
REWRITE_RESULT=""

_rewrite_member_host() {
  local db_path="$1" self_host="$2" log_path="/tmp/mongod-rename.log"
  local args=(mongod --dbpath "$db_path" --bind_ip 127.0.0.1 --port "$MONGO_PORT" --fork --logpath "$log_path")

  if [[ -n "${MONGO_WIREDTIGER_CACHE_GB:-}" ]]; then
    args+=(--wiredTigerCacheSizeGB "$MONGO_WIREDTIGER_CACHE_GB")
  fi

  # No --replSet and no --keyFile: a standalone, bound to localhost and gone
  # within seconds, is the only mode in which the configuration can be edited.
  if ! _as_mongodb "${args[@]}" >/dev/null; then
    REWRITE_RESULT="error: the temporary standalone did not start: $(tail -n 1 "$log_path" 2>/dev/null)"
    return 0
  fi

  REWRITE_RESULT="$(mongo_eval_local "
    const local = db.getSiblingDB('local');
    const conf = local.system.replset.findOne();
    if (!conf) {
      print('missing');
    } else if (conf.members.length !== 1) {
      print('multi-member');
    } else {
      local.system.replset.updateOne({ _id: conf._id }, { \$set: { 'members.0.host': $(js_string "$self_host") } });
      print('rewritten');
    }
  " | tail -n 1)" || true

  if ! _as_mongodb mongod --dbpath "$db_path" --shutdown >/dev/null; then
    die "The temporary standalone mongod did not shut down cleanly." \
      "The service will restart and try again; no data is affected."
  fi

  REWRITE_RESULT="${REWRITE_RESULT:-error: no response from the temporary standalone}"
}

# The member's host is written into the replica set configuration by
# rs.initiate(), and it is the name mongod looks for when it starts. Rename the
# service and that name stops resolving: the node no longer recognises itself,
# reports NotYetInitialized, and neither rs.reconfig({ force: true }) nor
# rs.initiate() can bring it back from there.
#
# MongoDB's documented procedure for this ("Change Hostnames in a Replica Set")
# is to start the node as a standalone, rewrite the host in
# local.system.replset, and start it again — which is what this does, before
# the real mongod starts. The name the member was registered under is
# remembered on the volume, so the standalone only ever runs when that name has
# actually changed.
adopt_renamed_host() {
  local sentinel="$1" db_path="$2" self_host="$3" registered

  [[ -f "$sentinel" ]] || return 0
  registered="$(cat "$sentinel")"
  [[ "$registered" == "$self_host" ]] && return 0

  log_box WARN \
    "This node is registered in the replica set as ${registered}," \
    "but is now reachable as ${self_host} — the service was renamed." \
    "Rewriting the member's host before mongod starts. No data is touched."

  _rewrite_member_host "$db_path" "$self_host"

  case "$REWRITE_RESULT" in
    rewritten)
      write_state_file "$sentinel" "$self_host"
      log_info "Member host rewritten from ${registered} to ${self_host}."
      ;;
    multi-member | missing)
      # Either someone has grown the set by hand, or there is no configuration
      # to move. Neither is this node's to manage any more.
      rm -f "$sentinel"
      log_warn "Replica set configuration is ${REWRITE_RESULT}; leaving the member hosts untouched."
      ;;
    *)
      log_box ERROR \
        "Could not rewrite the member's host (${REWRITE_RESULT})." \
        "The data is intact. mongod will start, but cannot become PRIMARY until" \
        "the host is fixed. See docs/TROUBLESHOOTING.md — do NOT delete the volume."
      ;;
  esac
}

# --------------------------------------------------------------- bootstrap

# Always succeeds: this runs inside a background task under `set -e`, and a
# mongosh that exits non-zero must produce a state to report, not kill the task.
#
# rs.status() decides whether this node is a member, because rs.conf() cannot:
# a node holding a configuration it is not part of still returns it. When
# rs.status() fails, its error and whether local.system.replset holds a
# configuration tell the rest apart:
#   94 NotYetInitialized, nothing stored  the set was never created;
#   94 NotYetInitialized, stored          mongod has not accepted it (yet);
#   93 InvalidReplicaSetConfig            accepted, but this node is not in it.
_replica_set_state() {
  local password="$1" self_host="$2" output
  output="$(mongo_eval_local_auth "$password" "
    const describe = (conf) => conf._id + ' ' + conf.members.map((m) => m.host).join(',');
    let state;
    try {
      rs.status();
      const conf = rs.conf();
      if (conf.members.length !== 1) {
        state = 'multi-member';
      } else if (conf.members[0].host === $(js_string "$self_host")) {
        state = 'configured';
      } else {
        state = 'registered-as ' + conf.members[0].host;
      }
    } catch (error) {
      const conf = db.getSiblingDB('local').system.replset.findOne();
      if (error.code === 94) {
        state = conf ? 'loading ' + describe(conf) : 'uninitialised';
      } else if (error.code === 93 && conf) {
        state = 'removed ' + describe(conf);
      } else {
        state = 'error: ' + (error.codeName || error.message);
      }
    }
    print(state);
  " | tail -n 1)" || true
  printf '%s' "${output:-error: no response from mongod}"
}

# mongod answers hello() before it has finished loading its configuration, and
# loading it means resolving and contacting each member's host — half a minute
# when that host does not answer. Until then it reports NotYetInitialized, as
# if the configuration were one it will never accept, so judging the node in
# that window gets it wrong. Wait for mongod to make up its mind; a
# configuration still not accepted when the timeout runs out never will be.
#
# Errors are retried too. When mongod settles on a state it closes every
# client connection, so a check that happens to be in flight at that moment
# fails with "connection closed" — on Railway, at exactly the moment a node
# that missed itself goes REMOVED.
_settled_replica_set_state() {
  local password="$1" self_host="$2" deadline state
  deadline=$(($(date +%s) + BOOTSTRAP_TIMEOUT_SEC))

  while :; do
    state="$(_replica_set_state "$password" "$self_host")"
    if [[ "$state" != "loading "* && "$state" != "error: "* ]] || (($(date +%s) >= deadline)); then
      printf '%s' "$state"
      return 0
    fi
    sleep 2
  done
}

# Whether connecting to self_host reaches this very mongod. It is the question
# mongod asks of a configured host when it looks for itself, answered the same
# way: by comparing process ids. A name that merely resolves may still lead to
# the container this one replaced.
_name_reaches_self() {
  local self_host="$1" probe here there
  probe='print(db.hello().topologyVersion.processId.toHexString())'

  here="$(mongo_eval_local "$probe" | tail -n 1)" || return 1
  there="$(mongosh --quiet \
    "mongodb://${self_host}/?directConnection=true&connectTimeoutMS=2000&serverSelectionTimeoutMS=2000" \
    --eval "$probe" 2>/dev/null | tail -n 1)" || return 1

  [[ -n "$here" && "$here" == "$there" ]]
}

_wait_for_name_to_reach_self() {
  local self_host="$1" timeout="$2" deadline
  deadline=$(($(date +%s) + timeout))

  until _name_reaches_self "$self_host"; do
    (($(date +%s) < deadline)) || return 1
    sleep 2
  done
}

_initiate() {
  local self_host="$1" password="$2" sentinel="$3" script

  # rs.initiate() looks for this node under self_host and fails outright if the
  # name leads elsewhere, which it can for a while when a service is recreated
  # under the name of one that was just deleted.
  if ! _wait_for_name_to_reach_self "$self_host" "$DNS_TIMEOUT_SEC"; then
    log_warn "${self_host} does not lead to this node yet; trying rs.initiate() anyway."
  fi

  log_info "Initiating replica set '${REPLICA_SET_NAME}' with a single member: ${self_host}."

  script="rs.initiate({
    _id: $(js_string "$REPLICA_SET_NAME"),
    version: 1,
    members: [{ _id: 0, host: $(js_string "$self_host") }]
  })"

  if ! mongo_eval_local_auth "$password" "$script" >/dev/null; then
    log_box ERROR \
      "rs.initiate() failed for '${REPLICA_SET_NAME}'." \
      "Check that ${self_host} is the name other services use to reach this" \
      "one (MONGO_ADVERTISED_HOST, if set), then redeploy."
    return 1
  fi

  write_state_file "$sentinel" "$self_host"
}

# Reached only when this node recognises itself under a name other than the one
# it advertises — both resolve to it, so it is PRIMARY and an ordinary reconfig
# can move it. A rename where the old name no longer resolves never gets here:
# adopt_renamed_host has already dealt with it before mongod started.
_move_member_host() {
  local self_host="$1" password="$2" sentinel="$3" registered="$4" script

  if ! wait_for_writable_primary "$BOOTSTRAP_TIMEOUT_SEC"; then
    log_warn "Registered as ${registered} but never became PRIMARY; cannot move it to ${self_host}."
    return 1
  fi

  log_info "Moving the member from ${registered} to ${self_host}."
  script="const conf = rs.conf();
    conf.members[0].host = $(js_string "$self_host");
    conf.version += 1;
    rs.reconfig(conf);"

  if ! mongo_eval_local_auth "$password" "$script" >/dev/null; then
    log_box ERROR \
      "rs.reconfig() could not move the member to ${self_host}." \
      "It keeps answering as ${registered}; clients that cannot resolve that" \
      "name will fail to connect. See docs/TROUBLESHOOTING.md."
    return 1
  fi

  write_state_file "$sentinel" "$self_host"
}

# Reached when mongod has accepted a configuration that names exactly this
# node, under the name it advertises, and still did not find itself in it:
# when it looked, the name led somewhere else. On Railway that is a redeploy,
# with the private domain still answering with the previous container's
# address.
#
# mongod then settles into REMOVED, "waiting for reconfig or remote heartbeat".
# A single member never receives a heartbeat, so it would wait forever, with
# the data intact and no PRIMARY. Give it the reconfig instead: once the name
# reaches this process, re-applying the very same configuration makes mongod
# look for itself again, find itself, and elect itself PRIMARY. Only the
# version changes. It has to be forced because only a PRIMARY may reconfigure
# normally, which is harmless here: one member, nothing to roll back.
_rejoin_replica_set() {
  local self_host="$1" password="$2" sentinel="$3" result

  log_warn "mongod started while ${self_host} still led to another address, so it did not recognise itself in the replica set."
  log_info "Waiting for ${self_host} to lead to this node, then re-applying the same replica set configuration."

  if ! _wait_for_name_to_reach_self "$self_host" "$BOOTSTRAP_TIMEOUT_SEC"; then
    log_box ERROR \
      "${self_host} did not lead to this node within ${BOOTSTRAP_TIMEOUT_SEC}s, so it could" \
      "not rejoin its replica set and there is no PRIMARY. The data is intact." \
      "Restart the service, and see docs/TROUBLESHOOTING.md if that does not" \
      "help. Do NOT delete the volume, and do NOT run rs.initiate()."
    return 1
  fi

  result="$(mongo_eval_local_auth "$password" "
    const conf = db.getSiblingDB('local').system.replset.findOne();
    conf.version += 1;
    let result;
    try {
      const reply = db.adminCommand({ replSetReconfig: conf, force: true });
      result = reply.ok === 1 ? 'reconfigured' : 'error: ' + (reply.codeName || reply.errmsg);
    } catch (error) {
      result = 'error: ' + (error.codeName || error.message);
    }
    print(result);
  " | tail -n 1)" || true

  # The reply can be lost: mongod closes client connections again as it leaves
  # REMOVED. What counts is whether the node recognises itself now.
  if [[ "$result" != "reconfigured" &&
    "$(_settled_replica_set_state "$password" "$self_host")" != "configured" ]]; then
    log_box ERROR \
      "Re-applying the replica set configuration failed (${result:-no response})." \
      "The data is intact. Restart the service, and see docs/TROUBLESHOOTING.md" \
      "if that does not help. Do NOT delete the volume, and do NOT run rs.initiate()."
    return 1
  fi

  write_state_file "$sentinel" "$self_host"
  log_info "Replica set configuration re-applied; this node recognises itself as ${self_host} again."
}

ensure_replica_set() {
  local self_host="$1" password="$2" sentinel="$3" state

  if ! wait_for_replica_set_member "$BOOTSTRAP_TIMEOUT_SEC"; then
    log_error "mongod did not come up as a replica set member within ${BOOTSTRAP_TIMEOUT_SEC}s; skipping replica set checks."
    return 0
  fi

  state="$(_settled_replica_set_state "$password" "$self_host")"

  case "$state" in
    configured)
      # Also how a volume from before the sentinel existed gets one.
      write_state_file "$sentinel" "$self_host"
      log_info "Replica set '${REPLICA_SET_NAME}' is already initiated as ${self_host}; leaving it untouched."
      return 0
      ;;
    uninitialised)
      _initiate "$self_host" "$password" "$sentinel" || return 0
      ;;
    "registered-as "*)
      _move_member_host "$self_host" "$password" "$sentinel" "${state#registered-as }" || return 0
      ;;
    multi-member)
      rm -f "$sentinel"
      log_info "Replica set '${REPLICA_SET_NAME}' has more than one member; its topology is managed by hand, so it is left untouched."
      return 0
      ;;
    "removed ${REPLICA_SET_NAME} ${self_host}")
      _rejoin_replica_set "$self_host" "$password" "$sentinel" || return 0
      ;;
    "removed "* | "loading "*)
      log_box ERROR \
        "This node does not recognise itself in its replica set configuration." \
        "  configured: ${state#* }" \
        "  this node:  ${REPLICA_SET_NAME} ${self_host}" \
        "The data is intact. See docs/TROUBLESHOOTING.md. Do NOT delete the" \
        "volume, and do NOT run rs.initiate() — it cannot recover this state."
      return 0
      ;;
    *)
      log_error "Could not read the replica set status (${state}); skipping replica set checks."
      return 0
      ;;
  esac

  if wait_for_writable_primary "$BOOTSTRAP_TIMEOUT_SEC"; then
    log_box INFO "Replica set '${REPLICA_SET_NAME}' is ready; this node is PRIMARY as ${self_host}."
  else
    log_warn "Replica set configured, but this node did not become PRIMARY within ${BOOTSTRAP_TIMEOUT_SEC}s."
  fi
}
