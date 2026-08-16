# Vaurd Agent — Kubernetes deployment

Everything you need to run the [Vaurd Agent](https://github.com/Vaurd/vaurd-agent)
in your own Kubernetes cluster, in two interchangeable forms: a **Helm chart**
and a set of **plain YAML manifests**.

The agent runs entirely inside your network. It connects outbound to the Vaurd
platform and to your data sources; nothing needs to be exposed to the internet
unless you want to post events to it from outside.

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

## What's in this repository

| Path | What it is |
|---|---|
| [`charts/vaurd-agent`](charts/vaurd-agent) | The Helm chart. Source of truth for the published chart. |
| [`k8s/`](k8s) | Plain, numbered YAML manifests — the same deployment without Helm. |
| [`docs/HOSTING.md`](docs/HOSTING.md) | Maintainer docs: how the chart is packaged, released and listed. |
| [`.github/workflows/`](.github/workflows) | Chart linting on PRs, publishing on merge to `main`. |

Published charts are served from the `gh-pages` branch at
**https://vaurd.github.io/vaurd-agent-k8s**.

## What gets deployed

| Component | Processes | Replicas | Listens on |
|---|---|---|---|
| core | core | 1 (fixed) | gRPC `:5001` |
| ingestion | ingestion, scheduler | 2 | HTTP `:5002` |
| worker | evaluator, source-connector | 2 | gRPC `:5004` (pod-local) |
| nats | NATS with JetStream | 1 | `:4222`, `:8222` |

All three agent components mount **one shared `ReadWriteMany` volume** at
`/data`, holding the encrypted database (`/data/vaurd.db`) and the plugin
binaries the platform downloads after registration (`/data/plugins`).

Events flow through NATS: ingestion publishes them, the scheduler matches them
to flows, and evaluators execute those flows. Separately, every component calls
core over gRPC at start-up to obtain the database encryption key — so **core
must be running before anything else becomes ready**. It is normal for
ingestion and worker pods to restart once or twice on a first install.

## Requirements

- Kubernetes 1.25 or newer (Helm 3.8+ if you use the chart)
- A storage class supporting `ReadWriteMany` — or a single-node cluster, see
  [Single-node clusters](#single-node-clusters-minikube-k3s-kind)
- A Vaurd license token and the gRPC address of your Vaurd platform
- Network egress from the cluster to the platform and to your data sources

---

## Which one should I use?

|  | Helm chart | Raw manifests |
|---|---|---|
| Install | `helm install` from the published repo, nothing to clone | `kubectl apply -f k8s/` after editing placeholders |
| Configuration | `values.yaml` / `--set`, validated and templated | Hand-edit YAML, keep your edits on rebase |
| Upgrades | `helm upgrade`, with rollback and release history | `kubectl apply` again, diff it yourself |
| Multiple installs per cluster | Yes — release name prefixes every object | Needs manual renaming and namespace edits |
| Auditability | Rendered output via `helm template` | What you see is what is applied |
| Best for | Most users, GitOps with Helm support | Air-gapped clusters, policy review, kustomize bases |

**Use the chart unless you have a reason not to.** The manifests exist for
teams whose review process needs literal YAML, or who layer kustomize on top.
Both produce the same architecture.

---

## How-to: deploy with the Helm chart

### 1. Add the repository

```bash
helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
helm repo update
helm search repo vaurd/vaurd-agent --versions
```

### 2. Write a values file

For anything beyond a quick trial, keep settings in a file rather than a long
`--set` chain:

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

### 3. Install

```bash
helm install vaurd vaurd/vaurd-agent --version 0.1.0 \
  --namespace vaurd --create-namespace \
  -f my-values.yaml
```

Always pass `--version`. An unpinned install picks up whatever is newest at the
time, which makes deployments non-reproducible.

### 4. Verify

```bash
kubectl -n vaurd get pods -l app.kubernetes.io/instance=vaurd
kubectl -n vaurd logs deploy/vaurd-vaurd-agent-core
```

### Upgrading and rolling back

```bash
helm upgrade vaurd vaurd/vaurd-agent --version 0.2.0 -n vaurd -f my-values.yaml
helm history vaurd -n vaurd
helm rollback vaurd 1 -n vaurd
```

### Uninstall

```bash
helm uninstall vaurd -n vaurd
kubectl -n vaurd delete pvc -l app.kubernetes.io/instance=vaurd   # data is NOT auto-deleted
```

Full value reference: [`charts/vaurd-agent/README.md`](charts/vaurd-agent/README.md),
or `helm show values vaurd/vaurd-agent --version 0.1.0`.

---

## How-to: deploy with the raw manifests

The manifests are numbered in apply order and all live in
[`k8s/`](k8s). Clone this repository first, since you need to edit them.

### 1. Fill in the configuration

Open [`k8s/01-config.yaml`](k8s/01-config.yaml) and replace every
`<placeholder>`: the license token, the platform address and CA certificate,
and a NATS password (**in both Secrets** — the agent config and
`vaurd-nats-auth` must match).

### 2. Choose a storage class

In [`k8s/03-storage.yaml`](k8s/03-storage.yaml), uncomment `storageClassName`
and set it to a class that supports `ReadWriteMany`.

### 3. Set your image tags

The manifests reference `vaurd/vaurd-agent-*:v0.1.0`. Point them at your
registry and version, and uncomment `imagePullSecrets` in each workload if your
registry is private.

### 4. Apply, in order

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-config.yaml
kubectl apply -f k8s/02-nats.yaml
kubectl apply -f k8s/03-storage.yaml
kubectl apply -f k8s/04-core.yaml
kubectl apply -f k8s/05-ingestion.yaml
kubectl apply -f k8s/06-worker.yaml
```

Or apply the whole directory at once — Kubernetes reconciles the dependencies
itself, though pods restart a few times while they wait:

```bash
kubectl apply -f k8s/
```

### 5. Optionally expose ingestion

Edit the host in [`k8s/07-ingress.yaml`](k8s/07-ingress.yaml), then apply it.
See [Exposing the ingestion API](#how-to-expose-the-ingestion-api) below.

### 6. Verify

```bash
kubectl -n vaurd get pods
kubectl -n vaurd logs deploy/vaurd-agent-core
```

More detail, including the single-node variant:
[`k8s/README.md`](k8s/README.md).

---

## How-to: expose the ingestion API

Events are posted to the ingestion service at `POST /api/v1/ingest`. In-cluster
producers can use the Service directly and need no ingress:

```
http://vaurd-agent-ingestion.vaurd.svc.cluster.local:5002/api/v1/ingest
```

To reach it from outside the cluster, both forms use
[ingress-nginx](https://kubernetes.github.io/ingress-nginx/deploy/), which runs
the same way on every cluster — minikube, kind, k3s, EKS, GKE or AKS:

**Helm:**

```yaml
ingress:
  enabled: true
  className: nginx
  host: agent.example.com
  tls:
    enabled: true
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
```

**Manifests:** edit the `host` in `k8s/07-ingress.yaml` and apply it. TLS is
commented out there by default so it applies cleanly without a certificate on
hand; uncomment the `tls:` block and the cert-manager annotation for
production.

---

## How-to: run it on a laptop (minikube)

```bash
minikube start
minikube addons enable ingress
```

Single-node clusters have no `ReadWriteMany` storage class, so switch the
shared volume to `ReadWriteOnce` and pin every component to the one node:

```yaml
# minikube-values.yaml
persistence:
  accessMode: ReadWriteOnce

core:
  nodeSelector: { kubernetes.io/hostname: minikube }
ingestion:
  nodeSelector: { kubernetes.io/hostname: minikube }
worker:
  nodeSelector: { kubernetes.io/hostname: minikube }

ingress:
  enabled: true
  className: nginx
  tls:
    enabled: false
```

Set `ingress.host` to a `nip.io` name pointing at your cluster IP, which needs
no DNS setup — e.g. `vaurd.$(minikube ip).nip.io`:

```bash
helm install vaurd vaurd/vaurd-agent --version 0.1.0 \
  -n vaurd --create-namespace -f minikube-values.yaml \
  --set config.license='<token>' \
  --set config.platform.url='<manager-host>:5000' \
  --set nats.auth.password='<password>' \
  --set ingress.host="vaurd.$(minikube ip).nip.io"
```

With the raw manifests, make the equivalent edits: `accessModes:
ReadWriteOnce` in `03-storage.yaml`, and a `nodeSelector` under `spec:` in each
of `04-core.yaml`, `05-ingestion.yaml` and `06-worker.yaml`.

---

## Storage

The three components share one SQLite database file, so the volume must be
mounted read-write by pods on different nodes — that is what `ReadWriteMany`
provides. Known-good options:

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

### Single-node clusters (minikube, k3s, kind)

Skip `ReadWriteMany` entirely: use `ReadWriteOnce` and pin all three components
to the same node, as shown in the [minikube how-to](#how-to-run-it-on-a-laptop-minikube).

## Scaling

Ingestion and worker pods consume from NATS work queues, where each message is
delivered to exactly one consumer, so they scale freely:

```bash
kubectl -n vaurd scale deploy/vaurd-agent-worker --replicas=5      # manifests
helm upgrade vaurd vaurd/vaurd-agent -n vaurd -f my-values.yaml \
  --set worker.replicaCount=5                                       # chart
```

**Core must stay at one replica.** It runs singleton background tasks (platform
heartbeat, action and telemetry shipping) and owns parts of the shared
database. Its rollout strategy is `Recreate`, so the old pod is always gone
before the replacement starts.

## Troubleshooting

**Pods stuck in `Pending`.** The shared volume could not be provisioned. Check
`kubectl -n vaurd describe pvc` — usually the storage class is missing or does
not support `ReadWriteMany`.

**Ingestion or worker pods restarting.** They cannot reach core. Confirm core
is ready, then check its logs for a registration failure — a bad license token
or an unreachable platform URL shows up there.

**Core never becomes ready.** It cannot reach the Vaurd platform. Verify the
platform URL, the CA certificate, and that egress from the cluster is allowed.

**Configuration changes have no effect.** The agent reads settings only from
its mounted `config.yml`. Environment variables are ignored. With the chart, a
config change rolls the pods automatically; with the manifests, edit the Secret
and then `kubectl -n vaurd rollout restart deploy/vaurd-agent-core
deploy/vaurd-agent-ingestion deploy/vaurd-agent-worker`.

## Contributing

Chart changes go in `charts/vaurd-agent`. Bump `version` in `Chart.yaml` in the
same pull request — CI enforces it, and merging to `main` publishes the new
version automatically. See [`docs/HOSTING.md`](docs/HOSTING.md) for the release
process.
