# vaurd-agent Helm chart

Runs the Vaurd Agent in your own Kubernetes cluster. The agent connects outbound
to the Vaurd platform and to your data sources; nothing needs to be exposed to
the internet unless you want to post events to it from outside.

Prefer plain manifests? The same deployment is available as YAML in
[`../../k8s`](../../k8s).

## What gets deployed

| Component | Processes | Replicas | Listens on |
|---|---|---|---|
| `<release>-core` | core | 1 (fixed) | gRPC `:5001` |
| `<release>-ingestion` | ingestion, scheduler | 2 | HTTP `:5002` |
| `<release>-worker` | evaluator, source-connector | 2 | gRPC `:5004` (pod-local) |
| `<release>-nats` | NATS with JetStream | 1 | `:4222`, `:8222` |

All three agent components mount one shared `ReadWriteMany` volume at `/data`,
holding the encrypted database (`/data/vaurd.db`) and the plugin binaries the
platform downloads after registration (`/data/plugins`).

Events flow through NATS: ingestion publishes them, the scheduler matches them
to flows, and evaluators execute those flows. Separately, every component calls
core over gRPC at start-up to obtain the database encryption key — so core must
be running before anything else becomes ready.

## Requirements

- Kubernetes 1.25 or newer, Helm 3
- A storage class that supports `ReadWriteMany` (see [Storage](#storage))
- A Vaurd license token and the address of your Vaurd platform

## Install

The chart is published publicly, so there is nothing to clone:

```bash
helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
helm repo update
helm install vaurd vaurd/vaurd-agent --version 0.1.1 \
  --namespace vaurd --create-namespace \
  --set config.license='<your-license-token>' \
  --set config.platform.url='<manager-host>:5000' \
  --set persistence.storageClass='<your-rwx-storage-class>'
```

Working from a clone of this repository instead? Replace the chart reference
with the local path, `./charts/vaurd-agent`, and drop `--version`.

Always pass `--version`. An unpinned install picks up whatever is newest at the
time, which makes deployments non-reproducible.

For anything beyond a quick trial, put the settings in a file instead:

```yaml
# my-values.yaml
config:
  license: <your-license-token>
  platform:
    url: <manager-host>:5000
    caCert: |
      -----BEGIN CERTIFICATE-----
      <vaurd agent manager CA certificate>
      -----END CERTIFICATE-----
  sources:
    - name: mysql-source
      type: database_mysql
      params:
        host: mysql.databases.svc.cluster.local
        port: 3306
        user: <db-user>
        password: <db-password>
        database: <db-name>

persistence:
  storageClass: efs-sc
  size: 20Gi

ingestion:
  replicaCount: 3
worker:
  replicaCount: 5
```

```bash
helm install vaurd vaurd/vaurd-agent \
  --version 0.1.1 -n vaurd --create-namespace -f my-values.yaml
```

Verify:

```bash
kubectl -n vaurd get pods -l app.kubernetes.io/instance=vaurd
kubectl -n vaurd logs deploy/vaurd-vaurd-agent-core
```

It is normal for ingestion and worker pods to restart once or twice on a first
install, while core registers with the platform.

## Configuration

The agent reads settings only from a single `config.yml`, which the chart
renders into a Secret and mounts at `/etc/vaurd/config.yml` in every component.
Environment variables are ignored, so everything you need to change belongs in
`values.yaml`. Changing any config value rolls the pods automatically.

### Core values

| Key | Default | Description |
|---|---|---|
| `config.license` | `""` | License token from the Vaurd platform. Required. |
| `config.platform.url` | `""` | gRPC address of your Vaurd platform. Required. |
| `config.platform.caCert` | `""` | PEM CA certificate for the platform's TLS. |
| `config.sources` | `[]` | Data sources the agent connects to. |
| `config.plugins` | `[]` | Plugins to download from the platform, by name and version. |
| `config.telemetry` | `{}` | Telemetry batching and stream limits; see below. |
| `config.existingSecret` | `""` | Use your own Secret containing a `config.yml` key. |
| `persistence.storageClass` | `""` | Storage class for the shared volume. |
| `persistence.accessMode` | `ReadWriteMany` | Set to `ReadWriteOnce` on single-node clusters. |
| `persistence.existingClaim` | `""` | Use a PVC you created yourself. |
| `nats.enabled` | `true` | Deploy the bundled NATS server. |
| `nats.externalEndpoint` | `""` | Required when `nats.enabled` is false. |
| `nats.auth.username` | `natsuser` | Username for the bundled NATS server. |
| `nats.auth.password` | `""` | Generated when empty; required only for an external NATS server. |
| `nats.auth.existingNatsSecret` | `""` | Use your own Secret for the NATS credentials. |
| `ingestion.replicaCount` | `2` | |
| `worker.replicaCount` | `2` | |
| `worker.maxConcurrency` | `10` | Flows executed in parallel per worker replica. |
| `worker.maxDeliveryAttempts` | `""` | NATS redelivery limit for a failed flow execution. |
| `ingress.enabled` | `false` | Expose the ingestion API outside the cluster. |
| `image.tag` | `v0.1.0` | Applies to all three images. |
| `image.pullSecrets` | `[]` | Names of Secrets for a private registry. |

Run `helm show values vaurd/vaurd-agent --version 0.1.1` for the full
annotated list.

### Plugins and telemetry

`config.plugins`, `config.telemetry` and `worker.maxDeliveryAttempts` are
written to `config.yml` **only when you set them**. Left at their defaults the
keys are absent from the file entirely, and the agent applies its own defaults —
so you never have to restate a value just to keep it.

```yaml
config:
  # Downloaded from the platform after registration. flow_scheduler is
  # installed whether or not you list it; version defaults to latest.
  plugins:
    - name: database_postgres
      version: latest

  # Each key is independent — set one and the other three keep the agent's
  # defaults, shown here for reference.
  telemetry:
    batchSize: 100          # events per batch shipped to the platform
    batchWaitMs: 5000       # flush a partial batch after this long
    streamTtlSeconds: 60    # how long an event lives in the NATS stream
    maxBytes: 1073741824    # stream size cap before old messages are evicted

worker:
  # JetStream MaxDeliver: redelivery attempts for a flow execution that fails
  # or times out. 0 or less means unlimited.
  maxDeliveryAttempts: 3
```

A misspelled key under `config.telemetry` fails the render rather than being
silently dropped.

## Storage

The three components share one database file, so the volume must be mounted
read-write by pods on different nodes — that is what `ReadWriteMany` provides.
Known-good options:

| Platform | Storage class |
|---|---|
| AWS | EFS (`efs.csi.aws.com`) |
| Azure | Azure Files (`file.csi.azure.com`) |
| GCP | Filestore (`filestore.csi.storage.gke.io`) |
| Self-hosted | CephFS, or an NFS server with working POSIX locking |

> **Check file locking before you go to production.** SQLite relies on POSIX
> advisory locks to keep concurrent readers and writers consistent. The options
> above implement them correctly; some plain NFS servers do not, and a broken
> lock implementation can corrupt the database. If you are unsure, ask your
> storage provider whether `fcntl` byte-range locking is supported.

**Single-node clusters** (k3s, minikube, a lab cluster) can skip `ReadWriteMany`
by pinning every component to the same node:

```yaml
persistence:
  accessMode: ReadWriteOnce

core:
  nodeSelector: { kubernetes.io/hostname: my-node }
ingestion:
  nodeSelector: { kubernetes.io/hostname: my-node }
worker:
  nodeSelector: { kubernetes.io/hostname: my-node }
```

## Scaling

Ingestion and worker pods consume from NATS work queues, where each message is
delivered to exactly one consumer. Scale them freely:

```bash
helm upgrade vaurd vaurd/vaurd-agent \
  --version 0.1.1 -n vaurd -f my-values.yaml --set worker.replicaCount=8
```

Core is always deployed with **one replica**. It runs singleton background tasks
(platform heartbeat, action and telemetry shipping) and owns parts of the shared
database, so the chart does not expose a replica count for it. Its rollout
strategy is `Recreate`, meaning a brief gap in registration and telemetry during
upgrades.

## Enabling mTLS between components

By default core and source-connector serve plaintext gRPC inside the cluster. To
encrypt that traffic, generate a certificate set from the agent repository with
`make generate-certs`, then set all three values together:

```yaml
config:
  tls:
    serverCert: |
      -----BEGIN CERTIFICATE-----
      ...
    serverKey: |
      -----BEGIN RSA PRIVATE KEY-----
      ...
    caCert: |
      -----BEGIN CERTIFICATE-----
      ...
```

Setting only `caCert` makes clients attempt TLS against plaintext servers, and
every component will fail to start. Leave `config.tls.serverName` at
`vaurd-agent`; it must match the certificate's subject alternative name, not the
Kubernetes Service name.

## NATS credentials

You do not have to invent a password for the bundled NATS server. Leave
`nats.auth.password` empty and the chart generates one on install, keeps it in
the `<release>-nats-auth` Secret, and reuses that same value on every upgrade —
it reads the Secret back out of the cluster rather than rolling a new password
each time. Read it if you ever need it:

```bash
kubectl -n vaurd get secret vaurd-vaurd-agent-nats-auth \
  -o jsonpath='{.data.password}' | base64 -d
```

The agent itself takes every setting from its mounted `config.yml` — it does not
resolve Secret references — so the chart renders the same credentials into that
file, which is a Secret too.

**Set `nats.auth.password` explicitly if you render the chart yourself**
(`helm template`, or a GitOps tool such as Argo CD that renders offline).
Reusing the existing password depends on reading the cluster, which those paths
cannot do, so a generated password would differ on every render and roll the
pods each sync.

### Bringing your own Secret

```yaml
nats:
  auth:
    existingNatsSecret: my-nats-credentials
    # Defaults, override if your Secret uses different keys.
    existingNatsSecretUsernameKey: username
    existingNatsSecretPasswordKey: password
```

Nothing is generated, and the chart creates no Secret of its own. It still has
to read the credentials out of that Secret to render `config.yml`, so this
combination needs a live cluster; if you render offline, supply the whole config
yourself with `config.existingSecret` as well.

### Rotating the password

Set a new `nats.auth.password` (or update your own Secret) and run
`helm upgrade`. The NATS server and all three agent components restart, because
the credentials reach them through checksummed Secrets rather than being re-read
at runtime. Expect a few seconds of message-delivery pause while they roll.

## Using your own NATS

The bundled NATS is a single replica, suitable for evaluation. For production,
use the [official NATS chart](https://github.com/nats-io/k8s) or a managed
service:

```yaml
nats:
  enabled: false
  externalEndpoint: nats://nats.messaging.svc.cluster.local:4222
  auth:
    username: <nats-user>
    password: <nats-password>
```

Credentials are required here — an external server's password is not the
chart's to choose, so nothing is generated. `existingNatsSecret` works for this
case too, and keeps the password out of your values file.

## Uninstall

```bash
helm uninstall vaurd -n vaurd
```

Helm does not delete PersistentVolumeClaims. Remove the agent's data explicitly
once you are sure you no longer need it:

```bash
kubectl -n vaurd delete pvc -l app.kubernetes.io/instance=vaurd
```

## Troubleshooting

**Pods stuck in `Pending`.** The shared volume could not be provisioned. Check
`kubectl -n vaurd describe pvc` — usually the storage class is missing or does
not support `ReadWriteMany`.

**Ingestion or worker pods restarting.** They cannot reach core. Confirm core is
ready, then check its logs for a registration failure — a bad license token or
an unreachable `config.platform.url` will show up there.

**Core never becomes ready.** It cannot reach the Vaurd platform. Verify
`config.platform.url`, `config.platform.caCert`, and that egress from the cluster
to the platform is allowed.

## Publishing this chart

Maintainers: see [RELEASE.md](../../docs/RELEASE.md) for the pre-release
checklist, the chart versioning rules and how a version reaches the chart
repository.
