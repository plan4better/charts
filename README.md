# plan4better/charts

Helm charts maintained by [plan4better](https://plan4better.de). Each chart lives under `charts/<name>/` and is published to GitHub Container Registry as an OCI artifact at `oci://ghcr.io/plan4better/charts/<name>`.

## Available charts

| Chart | Description | App source |
|---|---|---|
| [goat](charts/goat/) | GOAT (Geo Open Accessibility Tool) — WebGIS platform for spatial analysis, accessibility modeling, and collaborative mapping. | [plan4better/goat](https://github.com/plan4better/goat) |

## Installing a chart

```sh
helm install <release-name> oci://ghcr.io/plan4better/charts/<chart-name> \
  --version <chart-version> \
  --namespace <namespace> --create-namespace \
  --values your-values.yaml
```

For example:

```sh
helm install goat oci://ghcr.io/plan4better/charts/goat \
  --version 0.1.0 \
  --namespace goat --create-namespace
```

## Verifying signatures

Charts are signed with [Sigstore cosign](https://github.com/sigstore/cosign) keyless via GitHub Actions OIDC. Verify with:

```sh
cosign verify ghcr.io/plan4better/charts/<chart-name>:<version> \
  --certificate-identity-regexp "https://github.com/plan4better/charts/.github/workflows/release.yml.*" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Releases

Chart releases use the tag convention `<chart-name>-<version>` (e.g. `goat-0.1.0`). Each tag triggers the [release workflow](.github/workflows/release.yml) which packages the chart, pushes it to ghcr.io, cosign-signs the digest, and creates a corresponding GitHub Release.

## Contributing

PRs welcome. CI runs `helm lint`, `helm unittest`, and `kubeconform` on every PR that touches `charts/**` — see [`ci.yml`](.github/workflows/ci.yml).

To work on a chart locally:

```sh
# Install dev plugins
helm plugin install https://github.com/helm-unittest/helm-unittest

# Sync sub-chart deps
helm dependency update charts/<chart-name>/

# Lint + test
helm lint --strict charts/<chart-name>/
helm unittest charts/<chart-name>/

# Render with a CI fixture
helm template my-release charts/<chart-name>/ -f charts/<chart-name>/ci/values-external-deps.yaml
```

## License

Each chart inherits the license of the application it deploys. See per-chart `LICENSE` or `Chart.yaml` for specifics. Repository tooling (workflows, scripts) is EUPL-1.2.
