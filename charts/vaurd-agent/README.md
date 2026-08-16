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
helm install vaurd vaurd/vaurd-agent --version 0.1.0 \
  --namespace vaurd --create-namespace \
  --set config.license='<your-license-token>' \
  --set config.platform.url='<manager-host>:5000' \
  --set nats.auth.password='<choose-a-password>' \
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

nats:
  auth:
    password: <choose-a-password>

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
  --version 0.1.0 -n vaurd --create-namespace -f my-values.yaml
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
| `config.existingSecret` | `""` | Use your own Secret containing a `config.yml` key. |
| `persistence.storageClass` | `""` | Storage class for the shared volume. |
| `persistence.accessMode` | `ReadWriteMany` | Set to `ReadWriteOnce` on single-node clusters. |
| `persistence.existingClaim` | `""` | Use a PVC you created yourself. |
| `nats.enabled` | `true` | Deploy the bundled NATS server. |
| `nats.externalEndpoint` | `""` | Required when `nats.enabled` is false. |
| `nats.auth.password` | `""` | Required unless you supply your own config Secret. |
| `ingestion.replicaCount` | `2` | |
| `worker.replicaCount` | `2` | |
| `worker.maxConcurrency` | `10` | Flows executed in parallel per worker replica. |
| `ingress.enabled` | `false` | Expose the ingestion API outside the cluster. |
| `image.tag` | `v0.1.0` | Applies to all three images. |
| `image.pullSecrets` | `[]` | Names of Secrets for a private registry. |

Run `helm show values vaurd/vaurd-agent --version 0.1.0` for the full
annotated list.

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
  --version 0.1.0 -n vaurd -f my-values.yaml --set worker.replicaCount=8
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

Maintainers: see [HOSTING.md](../../docs/HOSTING.md) for how the chart is
packaged, signed and published to the chart repository.
