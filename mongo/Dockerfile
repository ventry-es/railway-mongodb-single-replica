# MongoDB 9.0, pinned to the minor series on purpose.
#
# A major version bump refuses to start on a data directory written by the
# previous major, which surfaces as a crash-looping database and gets mistaken
# for data loss. Upgrades are a deliberate, documented operation — see
# docs/OPERATIONS.md.
FROM mongo:9.0

COPY --chmod=0755 scripts/ /opt/railway/

# Railway does not use Docker healthchecks, but docker-compose does: it is what
# makes the local test deployment wait for mongod before the e2e checks start.
HEALTHCHECK --interval=5s --timeout=5s --start-period=20s --retries=30 \
  CMD ["/bin/sh", "-c", "mongosh --quiet --port \"${MONGO_PORT:-27017}\" --eval 'quit(db.adminCommand(\"ping\").ok === 1 ? 0 : 1)'"]

ENTRYPOINT ["/opt/railway/entrypoint.sh"]
