# Composing the template

The recipe for building this in Railway's Template Composer.

Everything below is deliberate — the service name becomes a DNS name that is
written into the replica set configuration, and the mount path becomes the
identity of the volume.

## The service

| Service | Root directory | Volume | Notes |
| --- | --- | --- | --- |
| `mongodb` | `/mongo` | `/data` | The only service |

It uses this repository as its source. Build settings, the restart policy and
the required mount path come from `mongo/railway.json`, so there is nothing to
configure on the Settings tab.

The service name becomes `mongodb.railway.internal`, and that hostname is the
member's host in the replica set. Renaming the service later works — the node
moves itself to the new name on its next boot — but consumers have to redeploy
to pick up the new `MONGO_URL`.

Keep the mount path at exactly `/data`. Changing it on an existing service makes
Railway attach a new, empty volume.

## Variables

| Variable | Value |
| --- | --- |
| `MONGO_REPLICA_SET_NAME` | `rs0` |
| `MONGO_INITDB_ROOT_USERNAME` | `root` |
| `MONGO_INITDB_ROOT_PASSWORD` | `${{secret(48, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")}}` |
| `RAILWAY_RUN_UID` | `0` |
| `MONGO_URL` | `mongodb://${{MONGO_INITDB_ROOT_USERNAME}}:${{MONGO_INITDB_ROOT_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:27017/?replicaSet=${{MONGO_REPLICA_SET_NAME}}&authSource=admin` |

The password alphabet is alphanumeric on purpose, so it can be dropped into a
connection string without percent-encoding — a recurring source of
"authentication failed" reports.

There is no keyfile variable. The node generates its own on first boot; see
[Architecture](ARCHITECTURE.md#2-the-keyfile-never-comes-from-the-environment).

`RAILWAY_RUN_UID=0` lets the entrypoint set ownership on the volume; the
official image drops to the `mongodb` user before starting `mongod`.

`MONGO_URL` is what consuming services reference (`${{mongodb.MONGO_URL}}`)
instead of assembling their own. It keeps `replicaSet=` so drivers treat the
node as a replica set member — which is what enables transactions and change
streams. No default database is included; applications choose their own.

## Optional: a public endpoint for yourself

Applications use the private `MONGO_URL`. If you also want to reach the
database from your own machine, enable a TCP proxy on `mongodb` (Settings →
Networking, target port `27017`) and add one more variable:

| Variable | Value |
| --- | --- |
| `MONGO_PUBLIC_URL` | `mongodb://${{MONGO_INITDB_ROOT_USERNAME}}:${{MONGO_INITDB_ROOT_PASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/?directConnection=true&authSource=admin` |

Railway only injects `RAILWAY_TCP_PROXY_DOMAIN` and `RAILWAY_TCP_PROXY_PORT`
once the proxy exists, so add the proxy first. See
[Operations](OPERATIONS.md#reaching-the-database-from-outside-railway) for why
`directConnection=true` is required.

## Optional variables

Leave these unset unless you need them.

| Variable | Default | Effect |
| --- | --- | --- |
| `MONGO_WIREDTIGER_CACHE_GB` | unset | Cap the cache to the memory the plan provides |
| `MONGO_OPLOG_SIZE_MB` | unset | A larger oplog: change streams can resume from further back |
| `MONGO_PASSWORD_ROTATION` | `auto` | `off` leaves a changed root password unapplied |
| `MONGO_PASSWORD_ROTATION_TIMEOUT_SEC` | `180` | How long a rotation waits for the node to become PRIMARY |
| `MONGO_BOOTSTRAP_TIMEOUT_SEC` | `300` | How long the replica set checks wait for `mongod` |
| `MONGO_DNS_TIMEOUT_SEC` | `120` | How long to wait for the node's own name to resolve before restarting |
| `MONGO_ADVERTISED_HOST` | private domain | Override the hostname written into the replica set configuration |
| `MONGO_EXTRA_FLAGS` | unset | Extra `mongod` flags, appended verbatim |
| `MONGO_ALLOW_EPHEMERAL_DATA` | `false` | Skip the volume check. Local testing and CI only |

Give every variable a description in the composer — Railway expects it of
published templates, and it is the only documentation most people will read.

## Publishing and updating

Once the template is published, add its deploy link and a Deploy on Railway
button to the [README](../README.md) and the [CHANGELOG](../CHANGELOG.md).

Railway delivers template updates as a pull request against the consumer's copy
of the repository, so changes here reach existing deployments as code. Two
rules keep that safe:

1. **Never change the volume mount path** in a minor release. `/data` is part of
   the contract; changing it orphans every existing volume.
2. **Never change the paths under `/data/state`.** They are how an existing
   node remembers its keyfile, password, set name and host; a node that cannot
   find them treats itself as freshly provisioned.

Anything else — a MongoDB patch version, a new optional variable, a fix in the
entrypoint — is safe, because the node's state lives on the volume.

Record every change in [CHANGELOG.md](../CHANGELOG.md), and mark breaking ones
clearly: it is what a consumer sees when they are asked to accept an update.
