# Helm — Kubernetes Package Manager

## What Is Helm?

Helm is the package manager for Kubernetes. It lets you define, install, and upgrade even
the most complex Kubernetes applications. Helm uses a packaging format called **charts** — a
collection of files that describe a related set of Kubernetes resources.

Think of Helm as `apt` / `brew` for Kubernetes:
- A **chart** is a Helm package (like a `.deb` or formula)
- A **repository** is where charts are stored and shared
- A **release** is an instance of a chart running in a cluster

---

## Chart Structure

```
my-chart/
├── Chart.yaml            # Chart metadata (name, version, appVersion, dependencies)
├── .helmignore           # Files to exclude when packaging
├── values.yaml           # Default configuration values
├── values.schema.json    # JSON Schema validation for values (optional but recommended)
├── charts/               # Dependency charts (populated by `helm dependency update`)
└── templates/
    ├── _helpers.tpl      # Template helper functions (not rendered directly)
    ├── deployment.yaml
    ├── service.yaml
    ├── serviceaccount.yaml
    ├── hpa.yaml
    ├── pdb.yaml
    ├── ingress.yaml
    ├── NOTES.txt         # Post-install instructions printed to stdout
    └── tests/
        └── test-connection.yaml   # Helm test pods
```

### Chart.yaml Fields

| Field          | Description                                          |
|----------------|------------------------------------------------------|
| `apiVersion`   | `v2` (Helm 3 only) or `v1` (Helm 2 compatible)       |
| `name`         | Chart name — must match the directory name           |
| `description`  | Human-readable description                           |
| `type`         | `application` (deployable) or `library` (helpers)   |
| `version`      | SemVer of the chart itself                           |
| `appVersion`   | Version of the application being packaged            |
| `dependencies` | List of chart dependencies                           |

---

## Key Commands

### Create a New Chart

```bash
helm create my-chart
```

Scaffolds the standard chart directory structure. Remove unused templates before committing.

### Install a Chart

```bash
# Install with default values
helm install my-release ./my-chart

# Install into a specific namespace (create if missing)
helm install my-release ./my-chart \
  --namespace my-namespace \
  --create-namespace

# Install with custom values file
helm install my-release ./my-chart \
  -f values-prod.yaml

# Dry-run (no cluster changes) — useful for CI validation
helm install my-release ./my-chart \
  --dry-run --debug
```

### Upgrade a Release

```bash
# Upgrade with new values
helm upgrade my-release ./my-chart -f values-prod.yaml

# Install if not present, upgrade if present (idempotent — preferred in CI/CD)
helm upgrade --install my-release ./my-chart \
  --namespace my-namespace \
  --create-namespace \
  -f values-prod.yaml \
  --atomic \          # Roll back automatically on failure
  --timeout 5m
```

### Rollback a Release

```bash
# List release history
helm history my-release -n my-namespace

# Roll back to previous revision
helm rollback my-release -n my-namespace

# Roll back to a specific revision
helm rollback my-release 3 -n my-namespace
```

### Uninstall a Release

```bash
helm uninstall my-release -n my-namespace

# Keep release history (allows rollback after uninstall)
helm uninstall my-release -n my-namespace --keep-history
```

### Lint a Chart

```bash
# Lint with default values
helm lint ./my-chart

# Lint with production values (catches value-specific issues)
helm lint ./my-chart -f values-prod.yaml
```

### Render Templates Without Installing

```bash
# Render all templates to stdout
helm template my-release ./my-chart -f values-prod.yaml

# Render only a specific template
helm template my-release ./my-chart -s templates/deployment.yaml

# Pipe to kubectl apply (GitOps-adjacent pattern)
helm template my-release ./my-chart -f values-prod.yaml | kubectl apply -f -
```

### Package a Chart

```bash
# Package into a .tgz archive for distribution
helm package ./my-chart

# Package with a specific destination
helm package ./my-chart -d ./dist/

# Sign the package (requires GPG key)
helm package ./my-chart --sign --key 'Platform Team' --keyring ~/.gnupg/pubring.kbx
```

### Repository Management

```bash
# Add a chart repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add stable https://charts.helm.sh/stable

# Update repository cache
helm repo update

# Search for charts
helm search repo nginx
helm search hub wordpress   # Search Artifact Hub

# Show chart values
helm show values bitnami/nginx
```

### Inspect a Release

```bash
# List all releases in a namespace
helm list -n my-namespace

# List across all namespaces
helm list -A

# Show computed values of a running release
helm get values my-release -n my-namespace

# Show all manifests of a running release
helm get manifest my-release -n my-namespace
```

---

## Values Override Pattern

Helm merges values files in order — later files win. Use this to layer environments:

```
values.yaml           # Shared defaults (committed)
values-staging.yaml   # Staging overrides (committed)
values-prod.yaml      # Production overrides (committed)
values-local.yaml     # Developer overrides (gitignored)
```

### Installing with layered values

```bash
helm upgrade --install my-release ./my-chart \
  -f values.yaml \
  -f values-prod.yaml \
  --set image.tag="${GIT_SHA}"    # Final override — use sparingly
```

### When to use `--set` vs `-f`

| Use Case                        | Approach                   |
|---------------------------------|----------------------------|
| One-off values in CI            | `--set image.tag=abc123`   |
| Environment config              | `-f values-prod.yaml`      |
| Secrets (avoid in values files) | External secrets manager   |
| Structured/complex values       | Always use `-f` (not --set)|

---

## Best Practices

### 1. Always Quote Strings in Templates

```yaml
# Bad — numeric-looking string gets cast to int
version: {{ .Values.app.version }}

# Good
version: {{ .Values.app.version | quote }}
```

### 2. Use `required` for Mandatory Values

```yaml
# Fails at render time with a clear error if not set
image: {{ required "image.repository is required" .Values.image.repository }}
```

### 3. Pin Image Digests in Production

```yaml
# values-prod.yaml
image:
  repository: nginx
  # Never use :latest in production — it's not reproducible
  # Generate with: docker inspect --format='{{index .RepoDigests 0}}' nginx:1.27
  digest: sha256:a484819eb60211f5299034ac80f6a681b06f89e65866ce91f356ed7c72af059c
  tag: ""   # ignored when digest is set
```

Template logic to prefer digest over tag:

```yaml
image: "{{ .Values.image.repository }}{{ if .Values.image.digest }}@{{ .Values.image.digest }}{{ else }}:{{ .Values.image.tag | default .Chart.AppVersion }}{{ end }}"
```

### 4. Use `_helpers.tpl` for All Labels

Centralise label generation in `_helpers.tpl`. Never hardcode labels in resource templates —
this ensures the full `app.kubernetes.io/*` label set is applied consistently.

### 5. Validate with JSON Schema

Include a `values.schema.json` to catch configuration errors before deployment. Helm
validates values against the schema during `install`, `upgrade`, `lint`, and `template`.

### 6. Set `revisionHistoryLimit`

```yaml
# Keep only 5 ReplicaSets to avoid etcd bloat
revisionHistoryLimit: 5
```

### 7. Use `--atomic` in CI/CD

```bash
helm upgrade --install my-release ./my-chart --atomic --timeout 5m
```

`--atomic` rolls back automatically if the release fails, leaving the cluster in a known
good state. Without it, a failed upgrade leaves the release in a broken state.

### 8. Never Store Secrets in values.yaml

Use external secret management:
- [External Secrets Operator](https://external-secrets.io/) + AWS Secrets Manager / Vault
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- Helm + Vault Agent injection (via annotations)

---

## Charts in This Repository

| Chart                        | Description                        | App Version |
|------------------------------|------------------------------------|-------------|
| [`helm/apache`](./apache/)   | Apache HTTP Server (production)    | 2.4         |
| [`helm/node-app`](./node-app/) | Node.js application              | latest      |

### Using the Apache Chart

```bash
# Install with defaults (development)
helm upgrade --install apache ./helm/apache \
  --namespace webapps \
  --create-namespace

# Install with production values
helm upgrade --install apache ./helm/apache \
  --namespace webapps \
  --create-namespace \
  -f helm/apache/values.yaml \
  --set image.digest="sha256:<pinned-digest>" \
  --atomic \
  --timeout 5m

# Lint before deploy
helm lint ./helm/apache

# Preview rendered templates
helm template apache ./helm/apache | kubectl apply --dry-run=client -f -

# Run Helm tests post-deploy
helm test apache -n webapps
```

### Using the Node App Chart

```bash
helm upgrade --install node-app ./helm/node-app \
  --namespace apps \
  --create-namespace \
  --atomic \
  --timeout 5m

# Run Helm tests
helm test node-app -n apps
```

---

## Installing Helm

See [`get_helm.sh`](./get_helm.sh) for an automated installer, or:

```bash
# macOS
brew install helm

# Linux — official script
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version
```

Helm 3 requires no server-side component (Tiller was removed). It stores release state as
Secrets in the release namespace.
