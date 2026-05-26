# GOAT Helm Chart

Helm chart for deploying GOAT (Geo Open Accessibility Tool) on Kubernetes.

## Scope (v0.2.0)

| Service | Default | Notes |
|---|---|---|
| **core** | ✅ enabled | Main API server |
| **web** | ✅ enabled | Next.js frontend |
| **windmill** server + default worker | ✅ enabled | Workflow engine; reuses goat Postgres connection |
| **windmill** print/tools/workflows workers | ❌ opt-in | Heavier requirements (chromium / tainted nodes / PVCs) |
| **geoapi** | ❌ opt-in | Needs DuckLake bootstrap |
| **accounts** | ❌ opt-in | Private image, needs pull secret |
| **processes** | ❌ opt-in | Needs DuckLake bootstrap |
| **caddy** custom-domains | ❌ opt-in | LoadBalancer Service + public DNS + ACME |

Not in the chart: `routing` (deployed alongside, owned by infra), `celery-flower` (not used).
See the design spec under `docs/` for the roadmap.

## Installing

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat \
  --version 0.2.0 \
  --namespace goat --create-namespace \
  --values your-values.yaml
```

## Quick start — bundled deps (development)

The chart ships with sensible defaults: a CloudNativePG-managed Postgres
cluster, a bundled Redis, the `core` + `web` deployments, and a windmill
server with one default worker. To install with everything bundled
(good for local k3d/kind testing):

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat
```

This deploys 4 Deployments: `goat-core`, `goat-web`, `goat-windmill-server`,
`goat-windmill-worker-default` (plus the CNPG operator and Redis sub-charts).
It requires the CloudNativePG operator's CRDs to be installable in your cluster.

When `windmill.server.enabled: true` (the default) and the CNPG cluster is
managed by the chart, the chart **automatically**:

- creates a separate `windmill` database in the cluster via the CNPG
  `bootstrap.initdb.postInitSQL`
- declares `windmill_user`, `windmill_admin` (BYPASSRLS, IN ROLE windmill_user),
  and `windmill_owner_user` (IN ROLES windmill_admin + windmill_user) as
  CNPG `managed.roles` so they're created and IN-ROLE grants applied
- generates the `windmill_owner_user` password (once, persisted via
  `helm.sh/resource-policy: keep`) into the K8s Secret
  `<release>-pg-windmill-cred`
- wires the windmill server + workers at it automatically — no extra values
  needed

### Windmill workspace + token bootstrap (post-install hook)

On `helm install` / `helm upgrade`, a one-shot Job (controlled by
`windmill.bootstrap.enabled`, default `true`) runs after the windmill
server is up and:

- waits for `goat-windmill-server` to return `200` on `/api/version`
- logs in as the superadmin (`windmill.bootstrap.adminEmail`, default
  `admin@windmill.dev`)
- rotates the default `changeme` password to a chart-managed value (random
  32-char; preserved across upgrades), or to an operator-supplied secret
  named in `windmill.bootstrap.adminPasswordSecret`
- creates the `windmill.bootstrap.workspace` workspace (default `goat`)
  if missing
- mints a non-expiring API token and writes it to K8s Secret
  `<release>-windmill-token` (`token` key)

Hook RBAC is minimal — a release-namespace `Role` granting `create` on
Secrets in the namespace, plus `get/patch/update` scoped to the token
Secret's name only.

To plug `processes` into the bootstrapped token, set:

```yaml
processes:
  extraEnv:
    - name: WINDMILL_URL
      value: "http://{{ include \"goat.fullname\" . }}-windmill-server"
    - name: WINDMILL_WORKSPACE
      value: "goat"
    - name: WINDMILL_TOKEN
      valueFrom:
        secretKeyRef:
          name: "{{ include \"goat.fullname\" . }}-windmill-token"
          key: token
          optional: true
```

Set `windmill.bootstrap.enabled: false` if you bootstrap windmill out-of-band
(e.g. via your own provisioning pipeline) — the hook then doesn't run.

### Optional: script sync

Set `windmill.scriptSync.enabled: true` to run a second post-install hook
(weight 20, after bootstrap) that uses the `windmill-worker-tools` image
to call `python -m goatlib.tools.sync_windmill` and
`python -m goatlib.tasks.sync_windmill`, pre-loading plan4better's
scripts/tasks into the workspace.

## Quick start — external Postgres

When deploying alongside a pre-existing Postgres cluster you have to
provision the goat (and, if you want windmill, the windmill) database +
users yourself, *then* point the chart at them. The chart only takes
operational connections — it never connects as superuser.

### 1. Run this SQL as your Postgres superuser

```sql
-- ===== goat database =====
CREATE USER goat WITH PASSWORD '<picked-by-you>';
CREATE DATABASE goat OWNER goat;
\c goat
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS pgrouting;

-- ===== windmill database (skip if windmill.server.enabled=false) =====
\c postgres
CREATE USER windmill_owner_user WITH PASSWORD '<picked-by-you>';
CREATE DATABASE windmill OWNER windmill_owner_user;

-- These role names are HARDCODED by windmill's migrations — do not rename.
-- Without them the windmill server's first migration aborts with
-- "role 'windmill_admin' does not exist".
CREATE ROLE windmill_user  WITH NOLOGIN;
CREATE ROLE windmill_admin WITH NOLOGIN BYPASSRLS;

-- windmill_admin must inherit windmill_user's table grants because
-- windmill runs runtime queries with `SET ROLE windmill_admin`.
GRANT windmill_user  TO windmill_admin;
GRANT windmill_admin TO windmill_owner_user;
GRANT windmill_user  TO windmill_owner_user;

-- windmill's sqlx pool ignores Postgres' default-search_path resolution,
-- so the migrations land in `public` only if we pin it explicitly here.
ALTER ROLE windmill_owner_user IN DATABASE windmill SET search_path = public;
```

### 2. Create K8s Secrets for the chart

```sh
kubectl create secret generic goat-postgres-creds \
  --from-literal=username=goat \
  --from-literal=password='<the goat password>'

kubectl create secret generic windmill-postgres-creds \
  --from-literal=username=windmill_owner_user \
  --from-literal=password='<the windmill password>'
```

### 3. Helm install

```yaml
postgresql:
  operator:
    enabled: false
  cluster:
    enabled: false
  external:
    host: "your-postgres.example.svc.cluster.local"
    database: goat
    existingSecret: goat-postgres-creds

windmill:
  db:
    reuseGoatConnection: false
    external:
      host: "your-postgres.example.svc.cluster.local"
      database: windmill
      existingSecret: windmill-postgres-creds

redis:
  enabled: true
```

The `existingSecret`s must contain `username` and `password` keys (or
override the key names via the `existingSecretUserKey` /
`existingSecretPasswordKey` fields).

> **Zalando-style installs (postgres-operator):** instead of running the SQL
> manually, declare `goat` and `windmill` as `preparedDatabases` in your
> `postgresql.acid.zalan.do` Cluster CR with `defaultUsers: true` (and for
> windmill, `schemas: public: defaultRoles: false` to suppress the
> Zalando-default `data` schema). The civitas-goat-addon does this; copy
> its `tasks/01_db.yml` for a working reference.

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
| `windmill.server.enabled` | bool | `true` | Deploy windmill server (workflow engine). |
| `windmill.workers.default.enabled` | bool | `true` | Deploy default windmill worker. |
| `windmill.workers.default.replicaCount` | int | `1` | Scale workers via this knob. |
| `windmill.workers.print.enabled` | bool | `false` | Heavier worker for PDF/atlas generation (chromium). |
| `windmill.workers.tools.enabled` | bool | `false` | Geodata pipelines; needs tainted node + PVC. |
| `windmill.workers.workflows.enabled` | bool | `false` | Same as tools (different WORKER_GROUP). |
| `caddy.enabled` | bool | `false` | Custom-domains feature (LoadBalancer + ACME on-demand TLS). |
| `caddy.acmeEmail` | string | `admin@example.com` | Email for Let's Encrypt issuance — override per deployment. |
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

### Heavy windmill workers — `tools` and `workflows`

These workers pin to a tainted node (`node.kubernetes.io/server-usage=geodata`, toleration `geodata=true:NoSchedule`) and mount a shared geodata PVC. They only run on clusters that have such a node pool. To enable:

```yaml
windmill:
  workers:
    tools:
      enabled: true
      replicaCount: 1
      persistence:
        enabled: true
        size: 200Gi
        # storageClassName: longhorn   # override if needed
    workflows:
      enabled: true
      replicaCount: 1
```

Without a tainted node available, the worker pods will sit in `Pending` and the chart's `helm install --wait` will time out. Don't enable them unless you've prepared the node side.

### `caddy` — custom-domains feature

Caddy fronts the web UI for customers who point their own DNS at GOAT. On-demand TLS issues Let's Encrypt certs only for domains that `goat-core /api/v2/custom-domain-lookup` approves. Requires:
- A `LoadBalancer` service (cluster must support it — metallb / cloud LB)
- Public DNS pointing at the LB IP for any customer domain
- A real email for ACME issuance (LE uses it for rate-limit notices)

```yaml
caddy:
  enabled: true
  acmeEmail: "ops@your-org.example"
  service:
    type: LoadBalancer
    loadBalancerIP: "203.0.113.5"   # optional, if you have a reserved IP
```

The chart creates a persistent volume for ACME state by default (1Gi); losing it triggers re-issuance of every cert, which hits Let's Encrypt rate limits. **Don't disable persistence in production.**

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

## Compatibility / version history

| Chart version | Adds | Notes |
|---|---|---|
| `0.2.0` | windmill (server + 4 workers), caddy (custom-domains) | Both off by default for opt-in; one knob each to enable |
| `0.1.0` | initial — core, web, geoapi, accounts, processes templates | First public release |

## License

EUPL-1.2.
