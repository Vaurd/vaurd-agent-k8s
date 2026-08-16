# Publishing the vaurd-agent chart

How the chart in [`../charts/vaurd-agent`](../charts/vaurd-agent) reaches
users. This document is for maintainers — users only need the
[repository README](../README.md) and the
[chart README](../charts/vaurd-agent/README.md).

```bash
helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
helm install vaurd vaurd/vaurd-agent --version 0.1.0
```

## How it works

The chart is distributed as an **HTTP chart repository**: an `index.yaml` plus
packaged `.tgz` files served over HTTPS. It works with every Helm 3 version,
supports `helm search repo`, and is listable on Artifact Hub.

Three moving parts, all inside this one repository:

| | Where |
|---|---|
| Chart source | `charts/vaurd-agent` on `main` |
| Packaged `.tgz` | Attached to a GitHub Release per chart version |
| `index.yaml` | Root of the `gh-pages` branch, served by GitHub Pages |

[`chart-releaser`](https://github.com/helm/chart-releaser-action) ties them
together on every push to `main` that touches `charts/**`. Because both the
releases and the Pages branch live here, the workflow's built-in
`GITHUB_TOKEN` is sufficient — there are no PATs or registry credentials to
manage.

---

## 1. One-time setup

Already done for this repository; recorded here so it can be recreated.

### Create the `gh-pages` branch

`chart-releaser` writes `index.yaml` to an existing branch — it will not create
one. An orphan branch keeps the published index out of the source history:

```bash
git checkout --orphan gh-pages
git rm -rf .
echo "Vaurd Helm charts" > index.md
git add index.md && git commit -m "chore: initialise chart repository"
git push origin gh-pages
git checkout main
```

### Enable GitHub Pages

**Settings** → **Pages** → source: **Deploy from a branch**, branch `gh-pages`,
folder `/`. Within a minute the repository is live at
`https://vaurd.github.io/vaurd-agent-k8s`.

Or from the CLI:

```bash
gh api -X POST repos/Vaurd/vaurd-agent-k8s/pages \
  -f 'source[branch]=gh-pages' -f 'source[path]=/'
```

### Actions permissions

Nothing to change. The repository default for `GITHUB_TOKEN` is read-only,
which is the safer setting and can stay that way: the release workflow
declares `permissions: contents: write` itself, and an explicit `permissions:`
block in a workflow takes precedence over the repository default.

If a release ever fails with a 403 pushing to `gh-pages` or creating a
release, check whether an *organisation* policy is capping workflow
permissions — org-level restrictions do override the workflow.

### Optional: custom domain

Point a `CNAME` DNS record at `vaurd.github.io`, then add a `CNAME` file
containing the domain to the root of `gh-pages`. Doing this early means you can
change hosts later without breaking every user's `helm repo add`.

---

## 2. Releasing a new version

There is no separate release command. **Merging a chart change to `main`
publishes it**, provided the chart version changed.

1. Edit the chart on a branch.
2. Bump `version` in `charts/vaurd-agent/Chart.yaml` — see
   [Versioning](#versioning). The PR lint job fails if you forget.
3. Update the `artifacthub.io/changes` annotation; it becomes the changelog
   users read on Artifact Hub.
4. Merge to `main`. The `Release Helm Chart` workflow packages the chart,
   creates the `vaurd-agent-<version>` GitHub Release with the `.tgz` attached,
   and updates `index.yaml` on `gh-pages`.

Publishing is keyed on the chart version: a version that already has a release
is skipped (`CR_SKIP_EXISTING: true`), so re-running the job is harmless and a
released version can never be silently replaced. To ship a fix you must bump
the version — which is the behaviour you want.

Verify as an outside user once Pages has rebuilt (~1 minute):

```bash
helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
helm repo update
helm search repo vaurd/vaurd-agent --versions
```

### Versioning

Two independent version numbers, and conflating them is the most common
packaging mistake:

- **`version`** — the chart's own SemVer. Bump it on *every* published change,
  including a typo fix in a template. Chart versions are immutable once
  released.
- **`appVersion`** — the agent release the chart deploys by default. Follows
  the agent's version, and is what `image.tag` defaults to.

| Change | `version` | `appVersion` |
|---|---|---|
| Template or values fix | patch | unchanged |
| New value, backwards compatible | minor | unchanged |
| New agent release, no chart changes | patch | new agent version |
| Removed/renamed a value, changed a default that alters behaviour | major | as applicable |

Do not ship a chart whose default image tag is `latest` — users cannot
reproduce or roll back such an install.

### Checking a change locally

Faster than a failed CI run:

```bash
helm lint charts/vaurd-agent \
  --set config.license=test \
  --set config.platform.url=manager:5000 \
  --set nats.auth.password=test

helm template va charts/vaurd-agent -n vaurd \
  --set config.license=test \
  --set config.platform.url=manager:5000 \
  --set nats.auth.password=test \
  | kubeconform -strict -summary -kubernetes-version 1.29.0
```

---

## 3. The workflows

| File | Trigger | Does |
|---|---|---|
| [`chart-lint.yml`](../.github/workflows/chart-lint.yml) | PR touching `charts/**` | `ct lint` (enforces the version bump), renders the chart and the raw manifests through `kubeconform` |
| [`chart-release.yml`](../.github/workflows/chart-release.yml) | Push to `main` touching `charts/**`, or manual dispatch | Packages, creates the GitHub Release, updates `index.yaml` on `gh-pages` |

`workflow_dispatch` on the release job lets you re-run a failed publish without
an empty commit.

To also cover the mTLS, external-NATS and ingress paths in linting, add a
`--values` matrix over a few `charts/vaurd-agent/ci/*-values.yaml` files —
`ct lint` picks up that directory automatically.

---

## 4. Signing releases

Optional but cheap, and it is what lets security-conscious users adopt the
chart without vendoring it. `helm package --sign` writes a `.tgz.prov`
provenance file alongside the chart, which users check with
`helm install --verify`:

```bash
helm package charts/vaurd-agent --sign --key 'Vaurd' --keyring ~/.gnupg/secring.gpg
```

`chart-releaser` uploads a `.prov` file automatically when it sits next to the
`.tgz`. Publish the public key — e.g. as `pubkey.gpg` on `gh-pages` — and link
it from the install docs, otherwise `--verify` is unusable.

---

## 5. Listing on Artifact Hub

Artifact Hub is where most people discover charts, and listing is free.

1. Add `artifacthub-repo.yml` to the **root of the `gh-pages` branch**. It
   proves ownership and unlocks the verified-publisher badge:

   ```yaml
   repositoryID: <uuid generated by Artifact Hub>
   owners:
     - name: Vaurd
       email: support@vaurd.io
   ```

2. Sign in at [artifacthub.io](https://artifacthub.io) with the GitHub account,
   then **Control Panel** → **Repositories** → **Add repository**:
   - Kind: Helm charts
   - URL: `https://vaurd.github.io/vaurd-agent-k8s`

3. Artifact Hub re-indexes every ~30 minutes. Once the `repositoryID` matches,
   the verified-publisher badge appears.

The chart README is rendered on the Artifact Hub page, so keep it user-facing —
that page is effectively the chart's landing page.

Fill in the discovery metadata in `Chart.yaml` before the first listing:

```yaml
icon: https://vaurd.io/img/logo.png   # must be a public, stable URL

annotations:
  artifacthub.io/category: integration-delivery
  artifacthub.io/license: Apache-2.0
  artifacthub.io/links: |
    - name: Documentation
      url: https://docs.vaurd.io
    - name: Source
      url: https://github.com/Vaurd/vaurd-agent-k8s
  artifacthub.io/changes: |
    - kind: added
      description: Initial public release
```

---

## 6. Maintenance rules

- **Versions are immutable.** Never delete and re-create a release with
  different content. Someone's CI pins it and will break in a way that is very
  hard to debug.
- **Keep old versions available.** Do not delete old GitHub Releases or rewrite
  `gh-pages` history; rollbacks depend on every prior `.tgz` staying reachable
  at the URL recorded in `index.yaml`.
- **Announce breaking changes** in `artifacthub.io/changes` and in the chart
  README, with a before/after values snippet. Renaming a value silently is the
  fastest way to lose trust in a chart.
- **Keep the raw manifests in step.** `k8s/` and `charts/vaurd-agent` describe
  the same deployment; a change to one usually belongs in the other.
- **Deprecating the chart**: set `deprecated: true` in `Chart.yaml` and publish
  one final version. Both Helm and Artifact Hub surface the flag to users.
- **Test upgrades, not just installs.** `helm upgrade` from the previous
  released version catches immutable-field errors (selector labels,
  `volumeClaimTemplates`) that a fresh `helm install` never hits.
