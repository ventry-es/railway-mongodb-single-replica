# shellcheck shell=bash
#
# Defence #1 against data loss: never let mongod write to ephemeral storage.
#
# A container's root filesystem is discarded on every deploy. If the volume is
# missing, or is attached at a different path than the one mongod uses, the
# cluster comes up looking perfectly healthy and then loses everything on the
# next redeploy. Failing loudly at boot is strictly better than that.

# A mount point sits on a different device than its parent directory.
# `mountpoint` is not present in the mongo image, so compare device ids.
_is_mount_point() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  [[ "$(stat -c '%d' "$path")" != "$(stat -c '%d' "$path/..")" ]]
}

assert_persistent_storage() {
  local path="$1"

  if [[ "${MONGO_ALLOW_EPHEMERAL_DATA:-false}" == "true" ]]; then
    log_box WARN \
      "MONGO_ALLOW_EPHEMERAL_DATA=true — persistence check skipped." \
      "Everything under ${path} will be LOST on the next deploy." \
      "This switch exists for local testing and CI only."
    return 0
  fi

  # Railway reports where it actually attached the volume. If that disagrees
  # with the path mongod is about to use, the template was mis-composed.
  if [[ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" && "${RAILWAY_VOLUME_MOUNT_PATH}" != "$path" ]]; then
    die "The volume is mounted at ${RAILWAY_VOLUME_MOUNT_PATH}, but this service stores data in ${path}." \
      "Edit the volume on this service and set its mount path to exactly ${path}." \
      "Changing the mount path of an existing service creates a NEW, empty volume —" \
      "check the old volume is still attached before assuming the data is gone."
  fi

  if ! _is_mount_point "$path"; then
    die "No volume is mounted at ${path}." \
      "mongod would write to the container filesystem, which Railway discards" \
      "on every deploy. Attach a volume to this service with mount path ${path}." \
      "For local testing only, set MONGO_ALLOW_EPHEMERAL_DATA=true."
  fi

  log_info "Persistent storage confirmed at ${path}."
}
