# Operations

## Checking on the node

```sh
railway ssh --service mongodb
mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin
```

```js
rs.status().members.map(m => ({ host: m.name, state: m.stateStr, health: m.health }))
rs.printReplicationInfo()   // oplog size and the time window it covers
```

A healthy deployment is one member, `PRIMARY`, `health: 1`, with its host set
to the service's private domain.

## What a deploy looks like

A service with a volume cannot overlap with its own previous deployment, so
Railway stops the old container before starting the new one. With one member,
that is a few seconds in which there is no database.

`mongod` receives `SIGTERM` as PID 1 and shuts down cleanly; the new container
starts, waits for its private domain to resolve, and elects itself PRIMARY.
Drivers wait for a server for up to 30 seconds by default
(`serverSelectionTimeoutMS`) and retry an interrupted operation once, so
applications usually see a pause rather than errors. Change streams resume on
their own from their last resume token, as long as the oplog still covers it.

Schedule deploys of this service for quiet moments. If even a few seconds of
downtime is unacceptable, this is the wrong template — use the three-member
one.

## Reaching the database from outside Railway

Applications belong on the private network. This is for you: Compass, `mongosh`
from your laptop, an export, a one-off migration.

The cheapest option needs no public exposure at all:

```sh
railway ssh --service mongodb
mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin
```

### A public endpoint

For a GUI client, enable a TCP proxy on `mongodb` — **Settings → Networking →
TCP Proxy**, target port `27017`. Railway then hands the service a public domain
and port, and injects them as `RAILWAY_TCP_PROXY_DOMAIN` and
`RAILWAY_TCP_PROXY_PORT`.

Add a variable so the resulting string is always in front of you instead of
assembled by hand:

| Variable | Value |
| --- | --- |
| `MONGO_PUBLIC_URL` | `mongodb://${{MONGO_INITDB_ROOT_USERNAME}}:${{MONGO_INITDB_ROOT_PASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/?directConnection=true&authSource=admin` |

**`directConnection=true` is not optional.** Without it the driver connects,
asks the replica set for its members, gets `mongodb.railway.internal`, which
does not resolve outside Railway, and fails — the failure mode that makes
people think the proxy is broken. With it, the driver talks to the node it
connected to. That node is the whole replica set, so nothing is lost:
transactions and change streams work through the proxy too.

**The password becomes the only thing between the internet and the database.**
Authentication is enforced and the generated 48-character password is strong,
so this is the same posture as any managed database with a public endpoint.
Rotate it if it has ever been pasted somewhere it should not have been, and
turn the proxy off when you no longer need it.

## Rotating the root password

Change `MONGO_INITDB_ROOT_PASSWORD` on `mongodb` and redeploy. The node detects
the drift, waits until it is PRIMARY, and calls `changeUserPassword`. The logs
report it:

```
Root password rotated to the value in MONGO_INITDB_ROOT_PASSWORD.
```

Consumers that reference `${{mongodb.MONGO_URL}}` pick up the new value when
they redeploy. To rotate manually instead, set `MONGO_PASSWORD_ROTATION=off` and
run `changeUserPassword` yourself — the sentinel at `/data/state/root-password`
must then be updated to match, or the next boot will try to rotate back.

## Renaming the service

Rename it. On its next boot the node notices that its private domain no longer
matches the host it is registered under, rewrites the host before `mongod`
starts, and comes back as PRIMARY under the new name:

```
This node is registered in the replica set as mongodb.railway.internal:27017,
but is now reachable as orders-db.railway.internal:27017 — the service was renamed.
Member host rewritten from mongodb.railway.internal:27017 to orders-db.railway.internal:27017.
```

Then redeploy the services that reference `MONGO_URL`, so they connect to the
new domain. Never rename a service and delete its volume in the same change.

## Backups

Volume backups are the primary mechanism — enable scheduled backups from the
volume's settings. Restoring a backup restores the keyfile, password sentinel
and replica set configuration along with the data, so the node boots straight
back into the same state.

For a portable copy, `mongodump` from inside the service:

```sh
railway ssh --service mongodb
mongodump --uri "mongodb://root:PASSWORD@localhost:27017/?directConnection=true&authSource=admin" \
  --archive=/tmp/dump.gz --gzip --oplog
```

`--oplog` makes the dump a consistent point-in-time snapshot even while writes
continue — one of the things a replica set gives you that a standalone does
not. Restore with `mongorestore --uri … --archive=… --gzip --oplogReplay`.

## Storage and memory

Volumes can be grown live but never shrunk, so start where you need to be.

`mongod` sizes its WiredTiger cache from the memory it can see, which on a
shared host is more than the container may use. On smaller plans set
`MONGO_WIREDTIGER_CACHE_GB` to roughly half the plan's memory to keep the
container from being killed under load.

`MONGO_OPLOG_SIZE_MB` sets how far back the oplog reaches. A change stream that
has been disconnected for longer than the oplog covers cannot resume and has to
start again from now; raise it if consumers can be offline for long, or if the
workload is write-heavy. It only takes effect when the oplog is first created;
on an existing node use `replSetResizeOplog`:

```js
db.adminCommand({ replSetResizeOplog: 1, size: 4096 })   // MB
```

## Upgrading MongoDB

Patch releases within 9.0 are picked up by rebuilding — the tag is `mongo:9.0`.

Major versions are a deliberate operation. `mongod` refuses to start on a data
directory written by a newer major, and skipping a major is not supported.

1. Take a volume backup.
2. Confirm the current compatibility version:
   ```js
   db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 })
   ```
   It must equal the version you are upgrading *from*.
3. Change the base image in `mongo/Dockerfile` to the next major and deploy.
4. Once the application has run on the new version long enough that you will
   not roll back:
   ```js
   db.adminCommand({ setFeatureCompatibilityVersion: "<new version>", confirm: true })
   ```

Raising the compatibility version is what makes the downgrade path unavailable,
which is why it comes last.

## Outgrowing one node

When a few seconds of downtime per deploy stops being acceptable, move to the
three-member replica set template rather than growing this one in place:

1. Deploy the three-member template alongside this one.
2. `mongodump --oplog` from here, `mongorestore --oplogReplay` into the new
   cluster's primary.
3. Point consumers at the new `MONGO_URL` and redeploy them.
4. Keep this service and its volume until you are sure, then remove them.

Check which MongoDB version the three-member template runs before you move.
Dump and restore carry ordinary data across a major version in either
direction, but an application that relies on features new in 9.0 needs a
cluster that runs 9.0.

Adding members to this replica set by hand is possible — the keyfile is at
`/data/state/keyfile`, and other members would need it byte for byte — but this
template stops managing the topology the moment there is more than one member,
so you would be operating the result yourself.
