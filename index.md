# Vaurd Helm charts

Helm chart repository for the [Vaurd Agent](https://github.com/Vaurd/vaurd-agent-k8s).

```bash
helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
helm repo update
helm search repo vaurd/vaurd-agent --versions
```

Install:

```bash
helm install vaurd vaurd/vaurd-agent --version 0.1.0 \
  --namespace vaurd --create-namespace \
  --set config.license='<your-license-token>' \
  --set config.platform.url='<manager-host>:5000' \
  --set nats.auth.password='<choose-a-password>' \
  --set persistence.storageClass='<your-rwx-storage-class>'
```

Documentation, values reference and plain Kubernetes manifests live on the
[`main` branch](https://github.com/Vaurd/vaurd-agent-k8s).

---

This branch is published by GitHub Pages and holds `index.yaml`, written
automatically by
[chart-releaser](https://github.com/helm/chart-releaser-action) on every chart
release. Do not edit it by hand.
