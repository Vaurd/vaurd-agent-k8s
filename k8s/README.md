# Deploying Vaurd Agent on Kubernetes

These manifests run the Vaurd Agent inside your own cluster. The agent connects
outbound to the Vaurd platform and to your data sources; nothing needs to be
exposed to the internet unless you want to post events to it from outside.

Prefer Helm? The same deployment is published as a public chart — no clone
required:

```bash
helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
helm install vaurd vaurd/vaurd-agent \
  --version 0.1.0 --namespace vaurd --create-namespace -f my-values.yaml
```

See [`../charts/vaurd-agent`](../charts/vaurd-agent) for its values and options.

## What gets deployed

| Component | Processes | Replicas | Listens on |
|---|---|---|---|
| `vaurd-agent-core` | core | 1 (fixed) | gRPC `:5001` |
| `vaurd-agent-ingestion` | ingestion, scheduler | 2 | HTTP `:5002` |
| `vaurd-agent-worker` | evaluator, source-connector | 2 | gRPC `:5004` (pod-local) |
| `vaurd-nats` | NATS with JetStream | 1 | `:4222`, `:8222` |

All three agent components mount one shared `ReadWriteMany` volume at `/data`.
That volume holds the encrypted database (`/data/vaurd.db`) and the plugin
binaries the platform downloads after registration (`/data/plugins`).

Events flow through NATS: ingestion publishes them, the scheduler matches them
to flows, and evaluators execute those flows. Separately, every component calls
core over gRPC at start-up to obtain the database encryption key — so **core
must be running before anything else becomes ready**.

## Requirements

- Kubernetes 1.25 or newer
- A storage class that supports `ReadWriteMany` (see [Storage](#storage) below)
- A Vaurd license token and the address of your Vaurd platform
- Network access from the cluster to the Vaurd platform and to your data sources

## Install

1. **Fill in your configuration.** Open `01-config.yaml` and replace every
   `<placeholder>`: the license token, the platform address and CA certificate,
   a NATS password (in both Secrets), and your data sources.

2. **Choose a storage class.** In `03-storage.yaml`, uncomment
   `storageClassName` and set it to a class that supports `ReadWriteMany`.

3. **Set your image tags.** The manifests reference `vaurd/vaurd-agent-*:v0.1.0`.
   Point them at your registry and the version you want to run. If your registry
   is private, uncomment the `imagePullSecrets` block in each workload.

4. **Apply, in order:**

   ```bash
   kubectl apply -f 00-namespace.yaml
   kubectl apply -f 01-config.yaml
   kubectl apply -f 02-nats.yaml
   kubectl apply -f 03-storage.yaml
   kubectl apply -f 04-core.yaml
   kubectl apply -f 05-ingestion.yaml
   kubectl apply -f 06-worker.yaml
   ```

   Or apply the whole directory at once — Kubernetes will reconcile the
   dependencies itself, though pods restart a few times while they wait:

   ```bash
   kubectl apply -f .
   ```

5. **Optionally expose ingestion.** `07-ingress.yaml` targets `ingressClassName:
   nginx` (ingress-nginx), which runs the same way on any cluster — on
   minikube, enable it with `minikube addons enable ingress`. Edit the `host`
   placeholder (on minikube, a `nip.io` hostname pointing at `minikube ip`
   works without touching DNS, e.g. `vaurd.<minikube ip>.nip.io`), then
   `kubectl apply -f 07-ingress.yaml`.

6. **Verify:**

   ```bash
   kubectl -n vaurd get pods
   kubectl -n vaurd logs deploy/vaurd-agent-core
   ```

   All pods should reach `Running` and `READY 1/1`. It is normal to see
   ingestion and worker pods restart once or twice on a first install while
   core registers with the platform.

## Storage

The three agent components share one database file, so the volume must be
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

**Single-node clusters** (k3s, minikube, a lab cluster) can skip `ReadWriteMany`
entirely. In `03-storage.yaml` change `accessModes` to `ReadWriteOnce`, then add
a node selector to all three workloads so they land on the same node:

```yaml
    spec:
      nodeSelector:
        kubernetes.io/hostname: <your-node-name>
```

## Scaling

`vaurd-agent-ingestion` and `vaurd-agent-worker` consume from NATS work queues,
where each message is delivered to exactly one consumer. Scale them with
`kubectl scale` or an HPA:

```bash
kubectl -n vaurd scale deploy/vaurd-agent-worker --replicas=5
```

`vaurd-agent-core` must stay at **one replica**. It runs singleton background
tasks (platform heartbeat, action and telemetry shipping) and is the only
writer for parts of the shared database. Its rollout strategy is `Recreate`
so the old pod is always gone before the replacement starts.

## Enabling mTLS between components

By default core and source-connector serve plaintext gRPC inside the cluster.
To encrypt that traffic, generate a certificate set from the agent repository:

```bash
make generate-certs
```

Then uncomment `server_cert`, `server_key` and `ca_cert` in `01-config.yaml`
and paste in the generated PEM blocks. All three keys must be set together —
setting `ca_cert` alone makes clients attempt TLS against plaintext servers and
every component will fail to start. Leave `server_name: vaurd-agent` as it is;
it must match the certificate's subject alternative name, not the Kubernetes
Service name.

After changing the Secret, restart the pods so they pick it up:

```bash
kubectl -n vaurd rollout restart deploy/vaurd-agent-core deploy/vaurd-agent-ingestion deploy/vaurd-agent-worker
```

## Using your own NATS

`02-nats.yaml` runs a single-replica NATS suitable for evaluation. For
production, use the [official NATS Helm chart](https://github.com/nats-io/k8s)
or a managed service: delete `02-nats.yaml`, and point
`services.nats.endpoint` in `01-config.yaml` at your cluster.

## Troubleshooting

**Pods stuck in `Pending`.** The shared volume could not be provisioned. Check
`kubectl -n vaurd describe pvc vaurd-agent-data` — usually the storage class is
missing or does not support `ReadWriteMany`.

**Ingestion or worker pods restarting.** They cannot reach core. Confirm core is
ready, then check its logs for a registration failure — a bad license token or
an unreachable `vaurd.manager_url` will show up there.

**Core never becomes ready.** It cannot reach the Vaurd platform. Verify
`vaurd.manager_url`, the `vaurd.ca_cert` block, and that egress from the cluster
to the platform is allowed.

**Configuration changes have no effect.** The agent reads settings only from the
mounted `config.yml`. Environment variables are ignored, so every setting must
be edited in the `vaurd-agent-config` Secret, followed by a rollout restart.
