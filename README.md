# MongoDB 9 Single-Node Replica Set for Railway

A MongoDB 9 replica set with exactly one member: transactions and change
streams on a single node, and a database that survives being redeployed.

Deploy one per app, per tenant or per environment: each deployment is an
isolated database reachable only over Railway's private network.

```
mongodb   /data   replica set rs0, one member   ← initiates itself, once
```

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/mongodb-9-single-replica-set?referralCode=7Npd7C&utm_medium=integration&utm_source=template&utm_campaign=generic)

## Why a replica set of one

A standalone `mongod` rejects anything that needs an oplog. Multi-document
transactions fail with `Transaction numbers are only allowed on a replica set
member or mongos`, change streams refuse to open, and libraries built on them
go down with them: Mongoose's `connection.transaction()` and `Model.watch()`,
and Prisma's MongoDB connector, which requires a replica set outright.

A single-member replica set has all of that, at the cost of one node.

What it does **not** have is failover. When the node restarts — a deploy, a
crash, a host problem — the database is unavailable for those seconds. Drivers
wait for a server for up to 30 seconds by default and retry an interrupted
operation once, so a short restart usually shows up as latency rather than
errors, but nothing takes over. If you need writes to keep working while a node
is down, use the
[three-member replica set template](https://railway.com/deploy/mongodb-8-replica-set?referralCode=7Npd7C&utm_medium=integration&utm_source=template&utm_campaign=generic)
instead.

## Your data is not going anywhere

Redeploying a template is the moment stateful services tend to lose data, so
each known way that happens is closed off explicitly:

| Failure | What this template does |
| --- | --- |
| Volume missing or mounted at the wrong path | `requiredMountPath` plus a runtime check — the node refuses to start rather than write to storage the platform discards |
| Keyfile regenerated | There is no keyfile variable to regenerate. The node generates its own on first boot and keeps it on the volume |
| `MONGO_INITDB_ROOT_PASSWORD` regenerated | The provisioned password is remembered on the volume, and drift is rotated in the database instead of locking you out |
| A redeploy re-initiating the set | `rs.initiate()` runs only when no replica set configuration exists at all |
| The service renamed | The member's host is rewritten before `mongod` starts, following MongoDB's documented procedure — otherwise the node never becomes PRIMARY again |
| `MONGO_REPLICA_SET_NAME` changed | The name is fixed by the first boot; the node keeps serving under it and says why |
| Private DNS slower than the container | `mongod` waits for its own name to resolve; started too early, a single member never recognises itself |
| Image tag drifting to a new major | Pinned to `mongo:9.0`; major upgrades are a documented, deliberate operation |
| Mount path changed by an update | `/data` is part of the template's contract and will not change in a minor release |

The reasoning behind each one is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
and [`tests/e2e.sh`](tests/e2e.sh) reproduces every failure against a real node
on each commit.

## Deploy

The exact service, variable and volume setup for Railway's Template Composer is
in [docs/TEMPLATE.md](docs/TEMPLATE.md). Nothing needs configuring by hand after
that: the node generates its own keyfile, the template generates the password,
and the replica set initiates itself on first boot.

## Connecting

Apps in the same Railway project and environment reach the database over the
private network:

```
mongodb://root:PASSWORD@mongodb.railway.internal:27017/?replicaSet=rs0&authSource=admin
```

The service exposes this as `MONGO_URL`, so a consuming service should
reference it rather than copy it:

```
DATABASE_URL=${{mongodb.MONGO_URL}}
```

Nothing changes in application code compared with any other MongoDB:

```js
await mongoose.connect(process.env.DATABASE_URL);

await mongoose.connection.transaction(async (session) => {
  await Order.create([{ total: 42 }], { session });
  await Stock.updateOne({ sku }, { $inc: { units: -1 } }, { session });
});
```

### Driver versions

MongoDB 9.0 talks to older drivers, and Mongoose 8.19, 9.6 and 9.11 have all
been run against this template — CRUD, aggregation, transactions and change
streams. Officially, though, the Node.js driver declares support for 9.0 from
**7.6**, which Mongoose ships from **9.10**. Upgrade when convenient; nothing
needs to change on the day you switch.

### From your own machine

Nothing is exposed publicly by default. To connect with Compass or `mongosh`,
enable a TCP proxy on `mongodb` (Settings → Networking, port `27017`) and add:

| Variable | Value |
| --- | --- |
| `MONGO_PUBLIC_URL` | `mongodb://${{MONGO_INITDB_ROOT_USERNAME}}:${{MONGO_INITDB_ROOT_PASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/?directConnection=true&authSource=admin` |

`directConnection=true` is required. Without it the driver asks the replica set
for its members, gets `mongodb.railway.internal`, and fails to resolve it from
outside. With one member there is nothing else to give up: the connection goes
to the only node there is, and transactions work through it.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `MONGO_REPLICA_SET_NAME` | `rs0` | Replica set name. Fixed by the first deploy. |
| `MONGO_INITDB_ROOT_USERNAME` | `root` | Root user, created on first boot. |
| `MONGO_INITDB_ROOT_PASSWORD` | generated | Root password. Changing it rotates the password in the database. |
| `MONGO_WIREDTIGER_CACHE_GB` | unset | Cap the cache to the memory the plan actually provides. |
| `MONGO_OPLOG_SIZE_MB` | unset | A longer oplog, so change streams can resume from further back. |
| `MONGO_PASSWORD_ROTATION` | `auto` | `off` disables automatic rotation of the root password. |
| `MONGO_ALLOW_EPHEMERAL_DATA` | `false` | Local and CI only. Never set this on Railway. |

The full list is in [docs/TEMPLATE.md](docs/TEMPLATE.md).

## Local development

```sh
cp .env.example .env
docker compose up
```

That brings up the same node on your machine. To run the checks CI runs:

```sh
./tests/e2e.sh              # every scenario
./tests/e2e.sh rename       # just one
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — how the node boots and how each data-loss defence works
- [Template](docs/TEMPLATE.md) — the Template Composer recipe and every variable
- [Operations](docs/OPERATIONS.md) — deploys, backups, credential rotation, version upgrades, outgrowing one node
- [Troubleshooting](docs/TROUBLESHOOTING.md) — what to do when the node misbehaves, and what never to do

## License

[MIT](LICENSE). Contributions welcome.
