# Troubleshooting

## Before anything else

**Do not delete the volume.** Almost every failure that looks like data loss is
a credential or configuration problem sitting in front of data that is
completely intact. Deleting the volume is the one action that turns a
recoverable problem into a real one.

Railway keeps a deleted volume for 48 hours. If one has already been deleted,
restore it from the volume's settings before doing anything else.

Start by reading the service's boot logs. The entrypoint reports what it found
and what it decided, in order, in lines tagged `[mongo]`.

## The node will not start

### `No volume is mounted at /data`

There is no volume attached, so `mongod` would write to storage the platform
discards on the next deploy. Attach a volume to the service with the mount path
exactly `/data`.

### `The volume is mounted at X, but this service stores data in /data`

The volume exists but is attached somewhere else. Set its mount path to `/data`.
If it was previously mounted correctly and someone changed it, Railway will have
created a second, empty volume — check the service's volumes before concluding
the data is gone.

### `Required variable X is not set`

A variable is missing or a reference did not resolve. Fix it in the Variables
tab and redeploy. [TEMPLATE.md](TEMPLATE.md) lists what the service expects.

### `X did not resolve within 120s`

The node's own private domain is not resolving, and starting `mongod` without
it would leave the database without a PRIMARY. The service restarts and tries
again on its own. If it keeps happening on Railway, check the service's private
networking; if `MONGO_ADVERTISED_HOST` is set, check that it names this node.

## The node starts but is never PRIMARY

### `This node does not recognise itself in its replica set configuration`

The configuration names a different host, or a different replica set, than the
node is running as. The log box shows both. The data is intact.

**Do not run `rs.initiate()`.** It cannot recover a node in this state; on
MongoDB 9.0 it leaves the node unusable.

If the hosts differ, tell the node what it used to be called and redeploy — the
entrypoint then moves the member to the current name before `mongod` starts:

```sh
railway ssh --service mongodb
printf '%s' 'OLD-HOST:27017' > /data/state/member-host
```

using the `configured:` host from the log box. If the replica set names differ,
put the configured name back instead, and redeploy:

```sh
printf '%s' 'CONFIGURED-NAME' > /data/state/replica-set-name
```

### `Could not rewrite the member's host`

The node was renamed, and the short-lived standalone that moves it to the new
name failed. The reason is in the box. The data is intact, and the next
deploy tries again — redeploy once before investigating further.

### `MONGO_REPLICA_SET_NAME is 'X', but this database was created as replica set 'Y'`

Harmless to the database: the node keeps running as `Y`. Clients connecting with
`replicaSet=X` cannot find it, though. Set `MONGO_REPLICA_SET_NAME` back to `Y`
so `MONGO_URL` is correct again.

## Credentials

### Clients get `Authentication failed`

The password in your connection string is not the one the database was
provisioned with. Check the service's logs:

- `Root password rotated…` — rotation completed; redeploy clients so they pick
  up the new value in `MONGO_URL`.
- `Root password drift detected…` with nothing after it — rotation is waiting
  for the node to become PRIMARY. See the section above.
- Nothing about passwords — the value in the environment is what the database
  expects, so the problem is in the client. Remember that a password with
  characters outside `[A-Za-z0-9]` must be percent-encoded in a URI.

### `Cannot rotate the root password: neither value authenticates`

The environment and the sentinel have both drifted from what is in the database
— typically because the password was changed by hand while
`MONGO_PASSWORD_ROTATION` was `off`.

The data is fine. Recover with the password you set manually:

```sh
railway ssh --service mongodb
mongosh -u root -p 'THE-PASSWORD-YOU-SET' --authenticationDatabase admin --eval \
  'db.getSiblingDB("admin").changeUserPassword("root", "VALUE-OF-MONGO_INITDB_ROOT_PASSWORD")'
printf '%s' 'VALUE-OF-MONGO_INITDB_ROOT_PASSWORD' > /data/state/root-password
```

If no password works at all, follow MongoDB's documented procedure of
restarting with authentication disabled to reset the user, rather than starting
over.

## Applications

### `Transaction numbers are only allowed on a replica set member or mongos`

The application is not talking to this node, or not as a replica set member.
Check that it uses `MONGO_URL` as given, with `replicaSet=` in it.

### `getaddrinfo ENOTFOUND mongodb.railway.internal`, or a server selection timeout, from outside Railway

Private domains only resolve inside Railway. From your machine, use the public
endpoint with `directConnection=true`, as described in
[Operations](OPERATIONS.md#reaching-the-database-from-outside-railway).
Without `directConnection=true` the driver connects, is told the member is
`mongodb.railway.internal`, and fails there.

### Connections pause during a deploy

Expected: with one member, the database is unavailable while the container is
replaced. Drivers wait up to `serverSelectionTimeoutMS` (30 seconds by default)
for it to come back. If deploys regularly take longer than that, raise the
timeout in the client — or move to the three-member template.

### A change stream reports that it cannot resume

It was disconnected for longer than the oplog covers. It has to start again
from the current time. Raise the oplog size — see
[Operations](OPERATIONS.md#storage-and-memory).

## Reproducing a problem locally

The local node is the same code, and `tests/e2e.sh` covers the failures above
against real containers:

```sh
cp .env.example .env
docker compose up
./tests/e2e.sh rename
```
