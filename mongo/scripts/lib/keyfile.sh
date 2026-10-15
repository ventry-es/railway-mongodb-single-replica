# shellcheck shell=bash
#
# Defence #2 against data loss: the keyfile is generated on the volume, once,
# and never comes from the environment.
#
# mongod will not enable authentication on a replica set without a keyfile,
# even one with a single member — it is what members would use to authenticate
# to each other. Nothing outside this node ever needs the key, so rather than a
# template variable that can be regenerated out from under a running database,
# it is created here on first boot and only ever lives on the volume.

# 756 random bytes encode to 1008 base64 characters, inside MongoDB's limit of
# 1024 — the same size `openssl rand -base64 756` produces.
readonly KEYFILE_RANDOM_BYTES=756

ensure_keyfile() {
  local keyfile_path="$1"

  if [[ -f "$keyfile_path" ]]; then
    log_info "Keyfile already present (fingerprint $(fingerprint "$(cat "$keyfile_path")"))."
    return 0
  fi

  # Written next to its final path and moved into place, so an interrupted
  # first boot can never leave a truncated key behind for the next one to trust.
  local tmp="${keyfile_path}.tmp"
  head -c "$KEYFILE_RANDOM_BYTES" /dev/urandom | base64 -w0 >"$tmp"
  chmod 0400 "$tmp"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown mongodb:mongodb "$tmp"
  fi
  mv -f "$tmp" "$keyfile_path"

  log_info "Keyfile generated at ${keyfile_path} (fingerprint $(fingerprint "$(cat "$keyfile_path")"))."
}
