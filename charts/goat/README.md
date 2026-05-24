# GOAT Helm Chart

Helm chart for deploying GOAT (Geo Open Accessibility Tool) on Kubernetes.

## Scope (v0.1.0)

This release ships templates for **core** and **web** (both enabled by default), plus
**geoapi**, **accounts**, and **processes** (templates included, default disabled — see
[Enabling optional services](#enabling-optional-services)).

Not yet included: `windmill`, `caddy`, `routing`. See the
[design spec](../../docs/superpowers/specs/2026-05-23-goat-helm-chart-design.md)
for the roadmap.

## Installing

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat \
  --version 0.1.0 \
  --namespace goat --create-namespace \
  --values your-values.yaml
```

## Quick start — bundled deps (development)

The chart ships with sensible defaults: a CloudNativePG-managed Postgres
cluster, a bundled Redis, and the `core` + `web` deployments. To install
with everything bundled (good for local k3d/kind testing):

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat --version 0.1.0
```

This deploys the `goat-core` API and `goat-web` Next.js frontend, backed by
a CNPG-managed Postgres cluster and Redis. It requires the CloudNativePG
operator's CRDs to be installable in your cluster.

## Quick start — external Postgres

When deploying alongside a pre-existing Postgres cluster:

```yaml
postgresql:
  operator:
    enabled: false
  cluster:
    enabled: false
  external:
    host: "your-postgres.example.svc.cluster.local"
    database: goat
    existingSecret: "your-postgres-secret"

redis:
  enabled: true
```

The `existingSecret` must contain `username` and `password` keys (or override
the key names via `postgresql.external.existingSecretUserKey` and
`postgresql.external.existingSecretPasswordKey`).

## Key values

| Key | Type | Default | Description |
|---|---|---|---|
| `core.enabled` | bool | `true` | Deploy `goat-core`. |
| `core.replicaCount` | int | `1` | Replicas. |
| `core.image.repository` | string | `plan4better/goat/core` | Image repository. |
| `core.image.tag` | string | `""` | Image tag; empty = `.Chart.AppVersion`. |
| `core.auth.enabled` | bool | `false` | Enable OIDC/Keycloak validation (Phase 2+). |
| `core.ingress.enabled` | bool | `false` | Create Ingress resource for core API. |
| `core.ingress.className` | string | `""` | Ingress controller name (`nginx`, `traefik`, …). |
| `core.config.*` | map | see values.yaml | Non-secret env vars (rendered as ConfigMap). |
| `web.enabled` | bool | `true` | Deploy `goat-web` (Next.js frontend). |
| `web.auth.enabled` | bool | `false` | Enable OIDC/Keycloak for the web frontend (Phase 2+). |
| `web.ingress.enabled` | bool | `false` | Create Ingress for the web UI (requires `hosts` populated). |
| `geoapi.enabled` | bool | `false` | Deploy `goat-geoapi`. Requires DuckLake bootstrap (see below). |
| `accounts.enabled` | bool | `false` | Deploy `goat-accounts`. Requires private image pull secret (see below). |
| `processes.enabled` | bool | `false` | Deploy `goat-processes`. Requires DuckLake bootstrap (see below). |
| `postgresql.cluster.enabled` | bool | `true` | Create CNPG Cluster CR. |
| `postgresql.operator.enabled` | bool | `true` | Install CNPG operator sub-chart. |
| `postgresql.external.host` | string | `""` | External Postgres host; required if cluster disabled. |
| `postgresql.external.existingSecret` | string | `""` | K8s Secret with `username`+`password`. |
| `redis.enabled` | bool | `true` | Bundled Redis sub-chart. |
| `redis.image.repository` | string | `bitnamilegacy/redis` | Bitnami moved free images to `bitnamilegacy` in Aug 2025. |
| `global.imageRegistry` | string | `""` | Mirror override for airgap deployments. |
| `global.security.allowInsecureImages` | bool | `true` | Required by bitnami sub-charts to accept `bitnamilegacy` images. |

For the full schema see `values.yaml` and `values.schema.json`.

## Enabling optional services

### `geoapi` and `processes` — DuckLake bootstrap

These services use DuckLake metadata stored in postgres. The default chart values include `DUCKLAKE_CREATE_IF_NOT_EXISTS: "true"` so the first deployment creates the DuckLake schema. After verifying it exists in your database, you can set this to `"false"` in your values to enforce schema stability.

To enable:

```yaml
geoapi:
  enabled: true
processes:
  enabled: true
```

### `accounts` — private image

The `accounts` service uses `ghcr.io/plan4better/goat-accounts`, a private GHCR package. Anonymous pull returns 401. To enable, create a pull secret in your release namespace and reference it:

```yaml
global:
  imagePullSecrets:
    - name: ghcr-pull-secret
accounts:
  enabled: true
```

Create the pull secret with a GitHub PAT that has `read:packages` scope:

```sh
kubectl -n <release-ns> create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<your-github-user> \
  --docker-password=<your-pat>
```

## Portability

The chart targets any conformant Kubernetes cluster:
- Standard `networking.k8s.io/v1 Ingress` only (no Traefik `IngressRoute`).
- StorageClass never hardcoded; defaults to cluster default.
- ServiceMonitor templates guarded on `monitoring.coreos.com/v1` CRD presence.
- Node selectors/tolerations always from values.

## Development

```sh
# install helm-unittest plugin
helm plugin install https://github.com/helm-unittest/helm-unittest

# run unit tests
helm unittest charts/goat/

# render with external-deps fixture
helm template my-release charts/goat/ -f charts/goat/ci/values-external-deps.yaml
```

## License

EUPL-1.2.
