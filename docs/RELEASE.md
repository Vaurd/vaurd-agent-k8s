# Releasing the vaurd-agent chart

How a change to [`../charts/vaurd-agent`](../charts/vaurd-agent) becomes a
version users can install. This document is for maintainers — users only need
the [repository README](../README.md) and the
[chart README](../charts/vaurd-agent/README.md).

There is no separate release command. **Merging a chart change to `main`
publishes it**, provided the chart version changed.

```
PR (chart-lint.yml)  →  merge to main (chart-release.yml)  →  GitHub Release
                                                            →  index.yaml on gh-pages
                                                            →  helm repo update
```

`chart-releaser` packages `charts/vaurd-agent`, attaches the `.tgz` to a GitHub
Release named `vaurd-agent-<version>`, and rewrites `index.yaml` on the
`gh-pages` branch that GitHub Pages serves at
`https://vaurd.github.io/vaurd-agent-k8s`.

Publishing is keyed on the chart version: a version that already has a release
is skipped (`CR_SKIP_EXISTING: true`), so re-running the job is harmless and a
released version can never be silently replaced. **To ship anything — even a
typo fix — you must bump the version.**

---

## 1. Before you push a new version

Work through this on the branch, before opening the PR. Everything here is
cheaper than a failed release or, worse, a bad version that can never be
withdrawn.

### Chart metadata

- [ ] **`version` bumped** in `charts/vaurd-agent/Chart.yaml` — see
      [Versioning](#2-versioning). CI fails the PR if you forget.
- [ ] **`appVersion` matches the agent release** the chart deploys by default.
- [ ] **`image.tag` in `values.yaml` is in step with `appVersion`.** The values
      file pins the tag explicitly (`tag: v0.1.0`) and does *not* derive it
      from `appVersion`, so bumping one without the other ships a chart that
      claims one agent version and deploys another. Never publish with
      `tag: latest` — users cannot reproduce or roll back such an install.
- [ ] **`artifacthub.io/changes` annotation updated.** It is the changelog
      users read on Artifact Hub. Use the real change kinds:

      ```yaml
      annotations:
        artifacthub.io/changes: |
          - kind: added
            description: Optional PodDisruptionBudget for core
          - kind: changed
            description: Default worker replicas raised to 2
      ```

      Valid kinds: `added`, `changed`, `deprecated`, `removed`, `fixed`,
      `security`.

### Content

- [ ] **Chart README updated** for any new, renamed or removed value. That page
      is rendered on Artifact Hub and is effectively the chart's landing page.
- [ ] **Breaking changes announced** in both the README and
      `artifacthub.io/changes`, with a before/after values snippet. Renaming a
      value silently is the fastest way to lose trust in a chart.
- [ ] **Raw manifests kept in step.** `k8s/` and `charts/vaurd-agent` describe
      the same deployment; a change to one usually belongs in the other.

### Verify locally

Faster than a failed CI run — this is what `chart-lint.yml` does:

```bash
helm lint charts/vaurd-agent \
  --set config.license=test \
  --set config.platform.url=manager:5000

helm template va charts/vaurd-agent -n vaurd \
  --set config.license=test \
  --set config.platform.url=manager:5000 \
  | kubeconform -strict -summary -kubernetes-version 1.29.0
```

- [ ] **Lint and render pass**, including the non-default paths the CI matrix
      does not cover yet — mTLS, external NATS, ingress.
- [ ] **Upgrade tested, not just install.** `helm upgrade` from the currently
      released version catches immutable-field errors (selector labels,
      `volumeClaimTemplates`) that a fresh `helm install` never hits:

      ```bash
      helm repo update
      helm install va vaurd/vaurd-agent --version <previous> -n vaurd --create-namespace -f my-values.yaml
      helm upgrade  va charts/vaurd-agent -n vaurd -f my-values.yaml
      ```

### Merge and confirm

1. Merge to `main`. `Release Helm Chart` runs on any push touching `charts/**`.
2. Watch the run: `gh run watch` — or re-run it later with
   `gh workflow run chart-release.yml`, which exists so a failed publish does
   not need an empty commit.
3. Confirm the GitHub Release `vaurd-agent-<version>` exists with the `.tgz`
   attached.
4. Verify as an outside user once Pages has rebuilt (~1 minute):

   ```bash
   helm repo add vaurd https://vaurd.github.io/vaurd-agent-k8s
   helm repo update
   helm search repo vaurd/vaurd-agent --versions
   ```

If a release fails with a 403 pushing to `gh-pages` or creating the release,
check whether an *organisation* policy is capping workflow permissions — the
workflow declares `permissions: contents: write` itself, and org-level
restrictions are the only thing that overrides that.

---

## 2. Versioning

Two independent version numbers, and conflating them is the most common
packaging mistake:

- **`version`** — the chart's own SemVer. Describes the *packaging*. Bump it on
  every published change, including a typo fix in a template. Chart versions
  are immutable once released.
- **`appVersion`** — the agent release the chart deploys by default. Describes
  the *payload*. Follows the agent's own version and moves only when the
  default image changes.

| Change | `version` | `appVersion` |
|---|---|---|
| Template or values fix, docs change | patch | unchanged |
| New value, backwards compatible | minor | unchanged |
| New agent release, no chart changes | patch | new agent version |
| Removed or renamed a value, changed a default that alters behaviour | major | as applicable |
| New agent release that also needs new chart values | minor or major | new agent version |

Rules that follow from `version` being immutable:

- **Never delete and re-create a release with different content.** Someone's CI
  pins that version and will break in a way that is very hard to debug. Ship a
  new patch instead.
- **Keep old versions reachable.** Do not delete old GitHub Releases or rewrite
  `gh-pages` history; rollbacks depend on every prior `.tgz` staying live at
  the URL recorded in `index.yaml`.
- **Pre-releases** (`0.2.0-rc.1`) are hidden from `helm search` and
  `helm install` unless the user passes `--devel`, which makes them a safe way
  to stage a risky change.
- **Deprecating the chart**: set `deprecated: true` in `Chart.yaml` and publish
  one final version. Both Helm and Artifact Hub surface the flag to users.

---

## 3. The workflows

| File | Trigger | Does |
|---|---|---|
| [`chart-lint.yml`](../.github/workflows/chart-lint.yml) | PR touching `charts/**` | `ct lint` (enforces the version bump), renders the chart and the raw manifests through `kubeconform` |
| [`chart-release.yml`](../.github/workflows/chart-release.yml) | Push to `main` touching `charts/**`, or manual dispatch | Packages, creates the GitHub Release, updates `index.yaml` on `gh-pages` |

Both run on the built-in `GITHUB_TOKEN` — the chart source, the releases and
the Pages branch all live in this repository, so there are no PATs or registry
credentials to manage.

To also cover the mTLS, external-NATS and ingress paths in linting, add a
`--values` matrix over a few `charts/vaurd-agent/ci/*-values.yaml` files —
`ct lint` picks up that directory automatically.

---

## Appendix: infrastructure

Already in place. Recorded here so it can be recreated or debugged.

### Where things live

| | Where |
|---|---|
| Chart source | `charts/vaurd-agent` on `main` |
| Packaged `.tgz` | Attached to a GitHub Release per chart version |
| `index.yaml` | Root of the `gh-pages` branch, served by GitHub Pages |

The chart is distributed as an **HTTP chart repository** — an `index.yaml` plus
packaged `.tgz` files over HTTPS. It works with every Helm 3 version, supports
`helm search repo`, and is listable on Artifact Hub.

### The `gh-pages` branch

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

Then **Settings** → **Pages** → source **Deploy from a branch**, branch
`gh-pages`, folder `/` — or:

```bash
gh api -X POST repos/Vaurd/vaurd-agent-k8s/pages \
  -f 'source[branch]=gh-pages' -f 'source[path]=/'
```

A custom domain (a `CNAME` DNS record at `vaurd.github.io` plus a `CNAME` file
in the root of `gh-pages`) is worth doing early: it lets you change hosts later
without breaking every user's `helm repo add`.

### Signing releases

Optional, and what lets security-conscious users adopt the chart without
vendoring it. `helm package --sign` writes a `.tgz.prov` provenance file, which
users check with `helm install --verify`:

```bash
helm package charts/vaurd-agent --sign --key 'Vaurd' --keyring ~/.gnupg/secring.gpg
```

`chart-releaser` uploads a `.prov` file automatically when it sits next to the
`.tgz`. Publish the public key — e.g. as `pubkey.gpg` on `gh-pages` — and link
it from the install docs, otherwise `--verify` is unusable.

### Artifact Hub listing

1. Add `artifacthub-repo.yml` to the **root of the `gh-pages` branch**; it
   proves ownership and unlocks the verified-publisher badge:

   ```yaml
   repositoryID: <uuid generated by Artifact Hub>
   owners:
     - name: Vaurd
       email: support@vaurd.io
   ```

2. Sign in at [artifacthub.io](https://artifacthub.io), then **Control Panel** →
   **Repositories** → **Add repository**: kind *Helm charts*, URL
   `https://vaurd.github.io/vaurd-agent-k8s`.

3. Artifact Hub re-indexes every ~30 minutes; the badge appears once the
   `repositoryID` matches.

Fill in the discovery metadata in `Chart.yaml` before the first listing — it is
not there yet:

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
