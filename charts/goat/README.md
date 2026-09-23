# GOAT Helm Chart

Helm chart for deploying GOAT (Geo Open Accessibility Tool) on Kubernetes.

## Scope (v0.5.0)

| Service | Default | Notes |
|---|---|---|
| **core** | ✅ enabled | Main API server |
| **web** | ✅ enabled | Next.js frontend |
| **catalog** | ✅ enabled | STAC API + MCP server; serves the catalog mirror |
| **geoapi** | ✅ enabled | Tiles + features (default changed in 0.5.0) |
| **processes** | ✅ enabled | OGC API Processes (default changed in 0.5.0) |
| **windmill** server + default worker | ✅ enabled | Workflow engine |
| **windmill** print/tools/workflows workers | ❌ opt-in | Heavier requirements (chromium / tainted nodes) |
| **caddy** custom-domains | ❌ opt-in | LoadBalancer Service + public DNS + ACME |

## Installing

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat \
  --version 0.5.0 \
  --namespace goat --create-namespace \
  --values your-values.yaml
```

## Quick start — bundled deps (development)

The chart ships with sensible defaults: a CloudNativePG-managed Postgres
cluster, a bundled Redis, and the 7 GOAT service Deployments (`core`, `web`,
`catalog`, `geoapi`, `processes`, `windmill` server + one default worker). To
install with everything bundled (good for local k3d/kind testing):

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat \
  --namespace goat --create-namespace \
  --set web.publicUrls.api=http://127.0.0.1:8000 \
  --set web.publicUrls.geoapi=http://127.0.0.1:8100 \
  --set web.publicUrls.processes=http://127.0.0.1:8300 \
  --set web.publicUrls.catalog=http://127.0.0.1:8400/stac \
  --wait --timeout 25m

# then, to open it locally (one terminal each, or background them):
kubectl -n goat port-forward svc/goat-web       3000:80
kubectl -n goat port-forward svc/goat-core      8000:80
kubectl -n goat port-forward svc/goat-geoapi    8100:80
kubectl -n goat port-forward svc/goat-processes 8300:80
kubectl -n goat port-forward svc/goat-catalog   8400:80
# -> http://127.0.0.1:3000
```

> ⚠️ **A bare `helm install` with no URLs white-screens the web UI.** The
> browser calls core, geoapi, processes and catalog directly, so it needs
> their *public* (browser-reachable) URLs; the web image ships literal
> `APP_NEXT_PUBLIC_*_URL` placeholders that its entrypoint replaces only
> with values it is given, and an unreplaced `NEXT_PUBLIC_API_URL` makes
> `new URL(...)` throw on first load. Set the four `web.publicUrls.*` as above
> (the port-forward addresses), or give `core`/`geoapi`/`processes`/`catalog`
> an ingress with a host — each URL is then derived from it (see "Key
> values"). The install NOTES print a WARNING when `api` cannot be resolved.

This deploys 7 Deployments: `goat-core`, `goat-web`, `goat-catalog`,
`goat-geoapi`, `goat-processes`, `goat-windmill-server`,
`goat-windmill-worker-default` (plus the CNPG operator's own Deployment, a
`goat-data` PersistentVolumeClaim (200Gi by default — see "The shared data
volume" below), and the bundled Redis's `goat-redis-master` /
`goat-redis-replicas` StatefulSets). It requires the CloudNativePG
operator's CRDs to be installable in your cluster.

A cluster that has never seen this chart before installs with that one
command too — see "Bootstrapping onto a fresh cluster" below for why no
sequencing is needed. `--wait` blocks until every pod is Ready; a first
install pulls several large images, hence the 25-minute timeout.

### Bootstrapping onto a fresh cluster

A fresh cluster needs **one** `helm install`, `--wait` included:

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat \
  --namespace goat --create-namespace \
  --values your-values.yaml --wait --timeout 25m
```

`scripts/smoke-k3d.sh` in this repo runs exactly that against a throwaway
k3d cluster with the full bundled profile (`ci/values-smoke.yaml`) and then
checks every service. (Before chart 0.5.0 this took three sequenced
`helm install`/`helm upgrade` calls; no phases remain.) Three things make it
work:

- **The CNPG operator's CRDs are vendored under `crds/`** (see the comment
  above `dependencies:` in `Chart.yaml`). Helm applies a chart's `crds/`
  directory BEFORE rendering or installing any templates, so the operator,
  its CRDs and this chart's Postgres `Cluster` CR are created in the same
  call. Without that, Helm resolves every resource's kind against the
  cluster's API discovery before creating anything and fails with `no
  matches for kind "Cluster" in version "postgresql.cnpg.io/v1"`.
- **The one-time bootstrap is done by init containers, not hooks.**
  geoapi and processes attach the DuckLake catalog read-only and cannot
  start until it exists; the windmill server and workers cannot start until
  their `windmill` database exists. Each of those Deployments carries an
  init container that creates (or finds) its dependency before the main
  container starts — `ducklake-init` on geoapi/processes (see "DuckLake
  catalog bootstrap" below) and `windmill-db-init` on the windmill server
  and every worker (see the windmill database notes below). Until 0.5.0
  both were post-install hooks, and with `--wait` Helm holds post-install
  hooks until every resource is Ready — while the pods that needed those
  hooks could not go Ready until they had run. That deadlock is what the
  old phases worked around. The init containers are idempotent: on an
  existing cluster they find everything in place and exit, and several
  pods racing on first start are safe (the loser retries and finds the
  work done).
- **`core.migrate` stays a hook** (post-install / pre-upgrade), which is
  fine: nothing needs the alembic schema to become Ready (core's
  `/api/healthz` is a static ping), so the migration runs once the
  release's pods are up.

On a fresh install, expect geoapi, processes and the windmill pods to sit in
`Init:0/1` for a minute or two while Postgres initialises — their init
containers are waiting for it. If one stays there, its logs say why:
`kubectl -n goat logs deploy/goat-geoapi -c ducklake-init` or
`kubectl -n goat logs deploy/goat-windmill-server -c windmill-db-init`.

If the CNPG operator/CRDs already exist in the cluster (a shared cluster
where another release owns them, or `postgresql.operator.enabled: false`
to use a pre-existing operator), nothing changes — vendored CRDs are a
no-op if the CRD already exists; Helm's `crds/` mechanism does not fail or
overwrite in that case.

**Caveat inherent to Helm's `crds/` mechanism, not this chart:** `crds/`
is install-only. Helm **never** upgrades or deletes CRDs from it on `helm
upgrade` — this is intentional, documented Helm behavior, to avoid an
upgrade silently deleting a CRD (and the custom resources depending on it)
out from under a running cluster. That means:
- Bumping the `cloudnative-pg` dependency version in `Chart.yaml` does
  **not** update an already-installed cluster's CRDs as part of `helm
  upgrade`. If a new chart version bumps that dependency, apply the new
  vendored CRDs yourself first: `kubectl apply -f
  charts/goat/crds/cloudnative-pg-crds.yaml` (or your own copy from the
  new `cloudnative-pg` subchart version), then run the upgrade.
- The vendored copy has to be kept in sync with the pinned
  `cloudnative-pg` version by hand — there is no automation for this. See
  the comment above `dependencies:` in `Chart.yaml` for the exact
  re-extraction steps.

When `postgresql.cluster.enabled: true` (the CNPG cluster is managed by
the chart) and `windmill.db.reuseGoatConnection: false` (the default),
the chart **automatically**, independently of whether
`windmill.server.enabled` is currently true (deliberately — see below):

- declares `windmill_user`, `windmill_admin` (BYPASSRLS, IN ROLE windmill_user),
  and `windmill_owner_user` (IN ROLES windmill_admin + windmill_user,
  CREATEDB) as CNPG `managed.roles`, reconciled continuously — they exist
  (and stay in sync) regardless of when `postgresql.cluster.enabled` first
  turned on relative to anything else
- generates the `windmill_owner_user` password (once, persisted via
  `helm.sh/resource-policy: keep`) into the K8s Secret
  `<release>-pg-windmill-cred`
- creates the separate `windmill` database via a `windmill-db-init` init
  container on the windmill server and on every worker. It runs `psql` from
  the Postgres image the Cluster itself runs (`postgresql.cluster.image`,
  as that image's `postgres` user, uid 26), waits until it can log in as
  `windmill_owner_user`, and — only if `pg_database` has no `windmill` row —
  self-serves `CREATE DATABASE` using that role's `CREATEDB` grant ("already
  exists" from a racing sibling pod counts as success), then pins the role's
  `search_path` in it. No extra image, no PyPI egress, no hook.
- wires the windmill server + workers at it automatically — no extra values
  needed

Leaving `postgresql.cluster.image` empty is not supported while the chart
creates the windmill database — rendering fails with a message saying so.

The database is deliberately **not** created via CNPG's
`bootstrap.initdb.postInitSQL` (a very early version of this chart tried
that). `postInitSQL` runs once, as part of the Postgres cluster's one-shot
initdb Job — before the cluster is even up, and before the operator's
`managed.roles` reconciliation has run for the first time. A
`postInitSQL` statement that references `windmill_owner_user` as the new
database's owner therefore fails initdb outright with `role
"windmill_owner_user" does not exist`, every time, regardless of any other
timing: `managed.roles` is never reconciled before `postInitSQL`, contrary
to what an earlier comment in this chart assumed. The `windmill-db-init`
init container sidesteps this by running later, and retrying until the role
genuinely exists. Both this and the non-existent-database problem it
replaces were found running this chart's k3d smoke test against a genuinely
fresh install.

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

### DuckLake catalog bootstrap (init container)

`geoapi` and `processes` attach to the DuckLake catalog **read-only**;
DuckDB refuses to attach if the catalog doesn't exist, so without it both
crashloop on a fresh install with "Existing DuckLake at metadata catalog
... does not exist".

With `ducklakeBootstrap.enabled: true` (**the default since 0.5.0**) both
Deployments get a `ducklake-init` init container that runs GOAT's own
idempotent bootstrap, `python -m goatlib.storage.ducklake_init` (GOAT
v3.0.2+): a read-write ATTACH that creates the catalog if missing and is a
no-op against an existing one. It runs in the component's **own image**
(DuckDB, goatlib and the DuckLake extensions are baked in, so nothing is
downloaded at run time and the catalog is created in exactly the metadata
format the service attaches), with the same ConfigMap, Postgres
credentials, `<component>.extraEnv` and `data` mount as the service. It
works against the chart-managed CNPG cluster or an external Postgres alike.

The catalog location is pinned explicitly, so the init container creates it
exactly where the services look: the geoapi and processes ConfigMaps both
carry

| Env var | Default | Set by |
|---|---|---|
| `DUCKLAKE_DATA_DIR` | `/app/data/ducklake` | `ducklakeBootstrap.dataDir` |
| `DUCKLAKE_CATALOG_SCHEMA` | `ducklake` | `ducklakeBootstrap.catalogSchema` |

(the same defaults GOAT's own `geoapi`/`processes` settings use). A
`geoapi.config.*` / `processes.config.*` key of the same name wins for that
component. The windmill workers read their DuckLake settings from their own
`extraEnv`/config — keep them pointed at the same schema and data dir.

The init container retries for a couple of minutes (Postgres may still be
starting). One failure is not retried: a **DuckLake catalog version
mismatch** — a catalog created by an older duckdb (metadata format 0.3) that
this image's DuckDB (format 1.0) refuses to attach. That one-way migration
is never done automatically; the init container prints guidance pointing at
`docs/ducklake-15-upgrade.md` in the main goat repo and fails, leaving the
pod in `Init:CrashLoopBackOff` until the catalog is migrated.

Set `ducklakeBootstrap.enabled: false` only if you manage the catalog
out-of-band.

> Before 0.5.0 this key switched a post-install hook Job (off by default)
> that ran a copy of the bootstrap script on `python:3.11-slim` and
> `pip install`ed duckdb at run time. That hook is gone. Its
> `ducklakeBootstrap.s3.*` values are no longer read: the init container
> takes S3 settings from the component's own config/`extraEnv`, like the
> service does.

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
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

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
| `core.image.tag` | string | `""` | Image tag; empty = `.Chart.AppVersion` (the GOAT release the chart is pinned to). |
| `core.auth.enabled` | bool | `false` | Enable OIDC/Keycloak validation (Phase 2+). |
| `core.ingress.enabled` | bool | `false` | Create Ingress resource for core API. |
| `core.ingress.className` | string | `""` | Ingress controller name (`nginx`, `traefik`, …). |
| `core.config.*` | map | see values.yaml | Non-secret env vars (rendered as ConfigMap). `S3_FORCE_PATH_STYLE=true` selects path-style addressing for any S3-compatible store; `MAX_UPLOAD_DATASET_FILE_SIZE` caps browser uploads (bytes, default 5 GB). Both must also be in the Windmill workers' `WHITELIST_ENVS`. |
| `web.enabled` | bool | `true` | Deploy `goat-web` (Next.js frontend). |
| `web.auth.enabled` | bool | `false` | Enable OIDC/Keycloak for the web frontend (Phase 2+). |
| `web.ingress.enabled` | bool | `false` | Create Ingress for the web UI (requires `hosts` populated). |
| `geoapi.enabled` | bool | `true` | Deploy `goat-geoapi`. Its `ducklake-init` init container creates the DuckLake catalog (see below). |
| `processes.enabled` | bool | `true` | Deploy `goat-processes`. Same `ducklake-init` init container as geoapi. |
| `ducklakeBootstrap.enabled` | bool | `true` | Render the `ducklake-init` init container on geoapi/processes (was a hook, off by default, before 0.5.0). |
| `ducklakeBootstrap.dataDir` / `.catalogSchema` | string | `/app/data/ducklake` / `ducklake` | DuckLake location, emitted as `DUCKLAKE_DATA_DIR` / `DUCKLAKE_CATALOG_SCHEMA` to geoapi, processes and their init containers. |
| `core.migrate.enabled` | bool | `true` | Run `alembic upgrade head` + `initial_data` as a Helm hook (post-install / pre-upgrade). |
| `core.migrate.waitForDbSeconds` | int | `300` | How long the migrate hook waits for Postgres on fresh installs. |
| `postgresql.cluster.enabled` | bool | `true` | Create CNPG Cluster CR. |
| `postgresql.cluster.image` | string | `ghcr.io/cloudnative-pg/postgis:18-3.6-system-trixie` | Postgres image for the bundled CNPG Cluster. **New in 0.5.0.** CNPG's own default image has no PostGIS, which GOAT's schema requires, so the bundled-Postgres path does not work without a PostGIS-capable image here; `""` falls back to the operator's own default (broken for this chart's `postInitApplicationSQL`). |
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
| `data.enabled` | bool | `true` | Create/mount the shared `data` volume (see below). |
| `data.existingClaim` | string | `""` | Use a pre-provisioned claim instead of creating one. |
| `data.accessMode` | string | `ReadWriteOnce` | **Set `ReadWriteMany` on multi-node clusters** with an RWX-capable StorageClass. |
| `data.size` | string | `200Gi` | PVC size when the chart creates it. |
| `data.storageClassName` | string | `""` | Falls back to `global.storageClass`, then the cluster default. |
| `catalog.enabled` | bool | `true` | Deploy `goat-catalog` (STAC API + MCP server). |
| `catalog.s3.bucket` | string | `""` | Catalog bucket for previews/assets; unset means those routes 404 by design. |
| `catalog.config.CATALOG_MCP_ALLOWED_HOSTS` | string | `'["*"]'` | `/mcp` Host allow-list (DNS-rebinding protection); narrow once you have a real hostname. |
| `catalog.auth.existingSecret` | string | `""` | OIDC secret with `server-url` + `realm` keys — a subset of `core.auth`'s shape; the same Secret can be reused. |
| `web.publicUrls.api` / `.geoapi` / `.processes` / `.catalog` | string | `""` | Browser-facing service URLs; each is derived from that service's own ingress (scheme from its TLS, host from its first entry) when empty. |
| `web.websiteUrl` | string | `""` | Home's blog + changelog feeds; the surfaces hide when empty. |
| `redis.external.host` | string | `""` | External Redis host, used when `redis.enabled: false`. |
| `redis.external.existingSecret` | string | `""` | Secret holding the external Redis password; omit for an unauthenticated Redis. |

For the full schema see `values.yaml` and `values.schema.json`.

## The shared data volume

One volume, seven mounts. The windmill **tools** and **workflows** workers write
to it — the catalog mirror (`sync_catalog`), the geoip database (`sync_geoip`),
materialized catalog layers and their PMTiles — and **catalog**, **core**,
**geoapi** and **processes** read from it (geoapi and processes read-write:
see the table below). Without a volume they all share, those features
silently do nothing: the catalog serves an empty STAC, core skips the geoip
lookup when placing a new project, and geoapi/processes find no materialized
layers.

| Component | Mount | Mode |
|---|---|---|
| catalog | `/app/data/catalog` (subPath `catalog`) | read-only |
| core | `/app/data/catalog`, `/app/data/geoip` (subPaths `catalog`, `geoip`) | read-only |
| geoapi | `/app/data` | read-write |
| processes | `/app/data` | read-write |
| windmill tools, workflows | `/app/data` | read-write |

> ⚠️ **Multi-node clusters need `ReadWriteMany`.** The default is
> `ReadWriteOnce`, which works out of the box on single-node and
> default-StorageClass clusters. On more than one node an RWO volume can only be
> mounted by one node, and pods scheduled elsewhere will not start. Set
> `data.accessMode: ReadWriteMany` **and** point `data.storageClassName` at an
> RWX-capable class (NFS, CephFS, Longhorn RWX), or supply your own claim with
> `data.existingClaim`. `helm install`/`upgrade` NOTES print a NOTE (not a
> failure — RWO is correct on a single node) whenever `data.accessMode` is
> `ReadWriteOnce` and more than one component would mount the shared volume —
> it cannot detect your node count, so review it on every install.


```yaml
data:
  enabled: true
  existingClaim: ""          # BYO claim; skips PVC creation
  accessMode: ReadWriteMany
  size: 200Gi
  storageClassName: nfs-csi
```

## Enabling optional services

### `geoapi` and `processes` — DuckLake bootstrap

Both default to enabled since chart 0.5.0. GOAT has no self-creating DuckLake
schema variable — `DUCKLAKE_CREATE_IF_NOT_EXISTS` does not exist in GOAT and
must not be reintroduced. Both services attach the DuckLake catalog
**read-only** at startup and cannot start until it exists; their
`ducklake-init` init container (`ducklakeBootstrap.enabled`, default `true`)
creates it first, so they need no extra step on a fresh cluster — see
"DuckLake catalog bootstrap (init container)" above. Set `geoapi.enabled:
false` / `processes.enabled: false` if you don't want them.


### `catalog` — STAC API and MCP server

Enabled by default since chart 0.5.0. Database-less: it serves the mirror
parquet from the shared `data` volume (see "The shared data volume" above).
With no mirror present it serves an empty but valid STAC API, so it is safe to
run before `sync_catalog` has ever run.

**Data previews and assets** (`/stac/items/{id}/preview`, thumbnails, styles)
are the only routes that read the catalog *bucket*. Leave `catalog.s3` unset and
they answer 404 — deliberately: an endpoint a deployment does not offer simply
is not there. The rest of the STAC API is unaffected.

```yaml
catalog:
  s3:
    bucket: goat-catalog
    endpointUrl: https://s3.example.com
    region: auto
    existingSecret: catalog-s3-credentials   # keys: access_key, secret_key
```

**MCP host allow-listing.** The `/mcp` Streamable HTTP transport has
DNS-rebinding protection. The default `'["*"]'` disables the check, since a
fresh deployment's hostname is not known ahead of time. Once you have one:

```yaml
catalog:
  config:
    CATALOG_MCP_ALLOWED_HOSTS: '["catalog.goat.example.com"]'
```

### Where new projects open — `DEFAULT_PROJECT_VIEW_STATE`

GOAT places a new project near whoever created it, by geolocating their IP
against the geoip database on the shared `data` volume (populated by the
windmill `sync_geoip` task). **In a self-hosted install that never fires**:
users arrive from private addresses, which are never geolocated. Pin your
deployment to its own region instead:

```yaml
core:
  config:
    DEFAULT_PROJECT_VIEW_STATE: '{"latitude":48.14,"longitude":11.57,"zoom":11,"min_zoom":0,"max_zoom":20,"bearing":0,"pitch":0}'
```

**All seven fields are required.** `InitialViewState`
(`apps/core/src/core/schemas/project.py` in the main goat repo) declares
`latitude`, `longitude`, `zoom`, `min_zoom`, `max_zoom`, `bearing` and `pitch`
with no defaults — a value missing any of them fails Pydantic validation. That
failure is **silent**: `configured_view_state()` catches it, logs "
`DEFAULT_PROJECT_VIEW_STATE is not a valid view state; ignoring it`", and
returns `None` — no startup error, no merge with defaults. An incomplete value
just quietly stops pinning the region, and new projects keep falling through
to the world view.

### Schema migrations — `core.migrate` (default on)

Every install/upgrade runs a Helm hook Job (`<release>-core-migrate`) before
the new pods start: `alembic upgrade head` followed by
`core.scripts.initial_data` (SQL functions, triggers, authz seed data — and
the default user/organization when `core.auth.enabled: false`). On fresh
installs it waits up to `core.migrate.waitForDbSeconds` for the bundled
Postgres to come up. A failed migration aborts the release and leaves the
running version untouched. Set `core.migrate.enabled: false` to manage the
schema out-of-band.

### Heavy windmill workers — `tools` and `workflows`

These workers pin to a tainted node (`node.kubernetes.io/server-usage=geodata`, toleration `geodata=true:NoSchedule`). They only run on clusters that have such a node pool. To enable:

```yaml
windmill:
  workers:
    tools:
      enabled: true
      replicaCount: 1
    workflows:
      enabled: true
      replicaCount: 1
```

Storage comes from the shared `data` volume (see "The shared data volume"
above) whenever `data.enabled: true` (the default) — both workers mount it
full read-write at `/app/data`. Each worker's own `persistence.*` block is
only used as a fallback when `data.enabled: false`, and creates a separate,
worker-specific PVC instead.

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
| `0.5.0` | GOAT v3.0.2: `catalog` service (STAC API + MCP); shared `data` volume; single-command fresh install (DuckLake + windmill DB bootstrap moved from hooks to init containers); `REDIS_URL`, web `NEXT_PUBLIC_*` and windmill `WHITELIST_ENVS` fixes; bundled Postgres image moves from CNPG's default major 17 to 18 (`ghcr.io/cloudnative-pg/postgis:18-3.6-system-trixie`) | BREAKING: `helm upgrade` DELETES `<fullname>-windmill-tools-data` and `<fullname>-windmill-workflows-data` unless you first `kubectl annotate` them `helm.sh/resource-policy=keep` (worker `persistence` superseded by `data`, no automatic migration; the upgrade fails until you do or set `windmill.workers.legacyPersistence.acknowledgeDeletion` — see upgrade note 1 below); geoapi + processes now default on |
| `0.4.0` | automatic schema migrations (`core.migrate.*` hook); `NEXT_PUBLIC_AUTH_DISABLED` → `NEXT_PUBLIC_AUTH` | BREAKING: flip the web auth flag in your values |
| `0.2.0` | windmill (server + 4 workers), caddy (custom-domains) | Both off by default for opt-in; one knob each to enable |
| `0.1.0` | initial — core, web, geoapi, processes templates | First public release |

### Upgrading 0.4.x → 0.5.0

1. **Worker storage moved — `helm upgrade` WILL DELETE your old worker data
   unless you annotate the old claims FIRST.**
   `windmill.workers.{tools,workflows}.persistence` is superseded by the
   top-level `data` volume (default `data.enabled: true`), and those workers
   now mount the shared claim at `/app/data` instead of their own PVC. At that
   default the old per-worker PVC templates render nothing, and Helm deletes
   every resource the previous revision had that the new one does not render:
   the claims `<fullname>-windmill-tools-data` and
   `<fullname>-windmill-workflows-data` — and, with the usual `Delete` reclaim
   policy, their PVs and data. `<fullname>` is `<release>-goat`, or just
   `<release>` when the release name already contains `goat` (release `goat`
   → `goat-windmill-tools-data`), or `fullnameOverride` when set; list them with
   `kubectl -n <ns> get pvc | grep windmill-`.

   **Step 1, BEFORE `helm upgrade`:** put the keep policy on the LIVE claims.
   Helm reads `helm.sh/resource-policy` from the object in the cluster at the
   moment it would delete it, so this is what stops the deletion (verified on
   k3d: an annotated claim survived the upgrade, an unannotated one went
   `Terminating`):

   ```sh
   kubectl -n <ns> annotate pvc \
     <fullname>-windmill-tools-data <fullname>-windmill-workflows-data \
     helm.sh/resource-policy=keep
   ```

   (Name only the claims that exist.) The annotation this chart's own
   `pvc.yaml` sets does not help on this hop: 0.4.x never set it, and a
   template the new release no longer renders applies nothing to the live
   claim.

   **Step 2:** run the upgrade. The claims are left in place, no longer
   managed by the release. Then either copy their data onto the shared
   volume, or reuse one of them as the shared volume with `data.existingClaim`
   — that is safe **only after step 1**: `data.existingClaim` on its own does
   not stop the deletion (the claim is still absent from the manifest, so
   Helm still deletes it; pvc-protection merely holds it `Terminating` while
   the old pod uses it, and the new pods cannot mount a `Terminating` claim),
   and naming one claim leaves the other one unprotected. Patching the bound
   PV(s) to `persistentVolumeReclaimPolicy: Retain` additionally keeps the
   volume if a claim is ever deleted, but the data is then only reachable by
   re-binding the PV to a new claim by hand.

   **The chart refuses the unsafe upgrade.** While
   `windmill.workers.legacyPersistence.acknowledgeDeletion` is `false` (the
   default), `helm upgrade` looks the legacy claims up (Helm `lookup`) and
   FAILS before touching anything if one of them belongs to this release,
   will not be rendered, and lacks the annotation; the error prints the exact
   `kubectl annotate` command. Set it to `true` only if you want the claims
   deleted. `lookup` returns nothing under `helm template` and client-side
   `--dry-run`, so offline rendering never trips the check (`--dry-run=server`
   does run it). The NOTES printed after an upgrade repeat the warning but
   come too late to act on; the annotation has to happen before.

   GitOps: Argo CD renders the chart with `helm template` (no `lookup`, so
   the guard never fires) and prunes by its own rules, which do not read
   `helm.sh/resource-policy`. Under Argo CD, disable pruning for those
   claims (`argocd.argoproj.io/sync-options: Prune=false` on the live
   claims) or copy the data out before syncing 0.5.0. Flux's
   helm-controller runs a real `helm upgrade`, so the steps above apply.

2. **geoapi and processes now default on.** If you were relying on the
   lightweight core+web default, set `geoapi.enabled: false` and
   `processes.enabled: false` explicitly.
3. **`GOAT_GEOAPI_HOST` → `GOAT_PROCESSES_URL`.** The chart no longer sets the
   old name. Core still reads it as a fallback, so an explicit override keeps
   working — but move it to `core.config.GOAT_PROCESSES_URL`.
4. **Check `data.accessMode`.** It defaults to `ReadWriteOnce`. On a
   multi-node cluster set `ReadWriteMany` with an RWX-capable StorageClass —
   see "The shared data volume" above.
5. **DuckLake bootstrap is now an init container, on by default.**
   `ducklakeBootstrap.enabled` now defaults to `true` and renders a
   `ducklake-init` init container on geoapi and processes instead of the old
   post-install hook; `ducklakeBootstrap.s3.*` is no longer read. The init
   container runs on every pod start, in the geoapi/processes image
   (DuckDB 1.5.4, DuckLake metadata format 1.0). If your catalog was created
   by an older bootstrap (duckdb 1.4.3, format 0.3), that DuckDB refuses to
   attach it: the init container stops with guidance and the pods stay in
   `Init:CrashLoopBackOff` — migrate first, per `docs/ducklake-15-upgrade.md`
   in the main goat repo (the services themselves would refuse that catalog
   too). The windmill database likewise moved from a hook to a
   `windmill-db-init` init container; `windmill.db.bootstrapImage` is gone.
6. **`postgresql.cluster.image` now has a default; it had none before.**
   0.4.x never set `spec.imageName` on the bundled CNPG `Cluster`, so CNPG
   applied its own default image — plain Postgres 17, no PostGIS. But
   0.4.x's `postInitApplicationSQL` already unconditionally ran `CREATE
   EXTENSION postgis` against that database, so *every* bundled-Postgres
   install's initdb Job failed outright with `extension "postgis" is not
   available`, and the Cluster never left initdb — this is the exact
   failure this chart's own k3d smoke test caught, run against the
   unmodified 0.4.x template before `postgresql.cluster.image` existed at
   all. In practice there is no working 0.4.x bundled-Postgres deployment
   to migrate, so setting this default in 0.5.0
   (`ghcr.io/cloudnative-pg/postgis:18-3.6-system-trixie`, Postgres 18) is
   not a live-upgrade hazard for anyone actually running the bundled path
   — there is nothing in the field it could break. It only matters if you
   worked around the 0.4.x bug yourself with your own custom
   `postgresql.cluster.image` override: CNPG does not perform a Postgres
   major-version change as a rolling update when `imageName` changes on an
   existing `Cluster`, so if your workaround image's major version differs
   from 18, keep your existing override in place through the upgrade
   rather than letting the new default apply underneath you.

## License

EUPL-1.2.
