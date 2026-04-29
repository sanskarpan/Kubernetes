# Flux CD

## What Is Flux?

Flux is a set of continuous and progressive delivery solutions for Kubernetes that are open
and extensible. It is a CNCF Graduated project and part of the GitOps Toolkit.

Unlike ArgoCD (which has a central server), Flux is a collection of Kubernetes controllers
that run in your cluster. Each controller manages a specific concern:

| Controller              | Responsibility                                             |
|-------------------------|------------------------------------------------------------|
| `source-controller`     | Pulls from Git repos, Helm repos, OCI registries, S3       |
| `kustomize-controller`  | Applies Kustomize overlays to the cluster                  |
| `helm-controller`       | Manages Helm releases via `HelmRelease` CRDs               |
| `notification-controller`| Sends alerts to Slack, Teams, PagerDuty, etc.             |
| `image-reflector-controller` | Scans image registries for new tags               |
| `image-automation-controller`| Updates manifests in Git when new images appear    |

---

## Installation via `flux bootstrap`

`flux bootstrap` installs Flux into your cluster AND creates a Git repository structure
that Flux uses to manage itself — fully GitOps from day one.

### Prerequisites

```bash
# Install the flux CLI
brew install fluxcd/tap/flux

# Verify prerequisites (checks cluster access, Flux compatibility)
flux check --pre
```

### Bootstrap with GitHub

```bash
# Export your GitHub PAT (needs repo scope)
export GITHUB_TOKEN=ghp_your_token_here

# Bootstrap Flux — installs controllers and commits manifests to GitHub
flux bootstrap github \
  --owner=your-org \
  --repository=your-kubernetes-repo \
  --branch=main \
  --path=gitops/clusters/production \
  --personal=false \
  --token-auth
```

After bootstrap, Flux commits its own manifests to `gitops/clusters/production/flux-system/`
in your repository. Future Flux upgrades are done by committing new manifests to this path.

### Bootstrap with GitLab

```bash
export GITLAB_TOKEN=your-token

flux bootstrap gitlab \
  --owner=your-group \
  --repository=your-kubernetes-repo \
  --branch=main \
  --path=gitops/clusters/production \
  --token-auth
```

### Bootstrap with Generic Git (SSH)

```bash
flux bootstrap git \
  --url=ssh://git@your-git-server/your-org/your-repo.git \
  --branch=main \
  --path=gitops/clusters/production \
  --ssh-key-algorithm=ecdsa
```

---

## Core Flux Resources

### GitRepository — Define a Source

A `GitRepository` tells Flux which Git repository to watch and how often to poll.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kube-platform
  namespace: flux-system
spec:
  interval: 1m           # Poll Git every 1 minute
  url: https://github.com/your-org/your-kubernetes-repo.git
  ref:
    branch: main
  secretRef:
    name: git-credentials   # Secret with 'username' and 'password' keys
```

Apply the Git credential secret:

```bash
flux create secret git git-credentials \
  --url=https://github.com/your-org/your-kubernetes-repo.git \
  --username=git \
  --password=${GITHUB_TOKEN}
```

### Kustomization — Apply Manifests

A `Kustomization` tells Flux which path in the GitRepository to apply (using Kustomize).

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./gitops/apps/production      # Path within the GitRepository
  prune: true                          # Delete resources removed from Git
  sourceRef:
    kind: GitRepository
    name: kube-platform
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: apache
      namespace: webapps
  timeout: 5m
  wait: true
```

### HelmRelease — Manage a Helm Release

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: apache
  namespace: webapps
spec:
  interval: 10m
  chart:
    spec:
      chart: ./helm/apache        # Path to chart in GitRepository
      sourceRef:
        kind: GitRepository
        name: kube-platform
        namespace: flux-system
      interval: 1m
  values:                         # Inline values override
    replicaCount: 2
    image:
      tag: "2.4"
  valuesFrom:                     # Load values from a ConfigMap or Secret
    - kind: ConfigMap
      name: apache-values-prod
      valuesKey: values.yaml
  upgrade:
    remediation:
      retries: 3    # Roll back after 3 failed upgrade attempts
  rollback:
    timeout: 5m
    cleanupOnFail: true
```

---

## Image Automation

Flux can watch container registries and automatically update image tags in Git manifests
when new images are pushed. This closes the loop for CI/CD.

### 1. Create an ImageRepository (scan a registry)

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: apache
  namespace: flux-system
spec:
  image: httpd
  interval: 5m    # Scan Docker Hub every 5 minutes
```

### 2. Create an ImagePolicy (filter tags)

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: apache
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: apache
  policy:
    semver:
      range: ">=2.4.0 <3.0.0"   # Only use 2.x tags
```

### 3. Mark the manifest for automation

In your Deployment manifest, add a marker comment:

```yaml
containers:
  - name: apache
    image: httpd:2.4 # {"$imagepolicy": "flux-system:apache"}
```

### 4. Create an ImageUpdateAutomation

```yaml
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageUpdateAutomation
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: kube-platform
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        email: fluxbot@example.com
        name: FluxBot
      messageTemplate: "chore(image): update {{range .Updated.Images}}{{.}}{{end}}"
    push:
      branch: main
  update:
    path: ./gitops
    strategy: Setters
```

---

## Flux vs ArgoCD Comparison

| Feature                    | Flux v2                                       | ArgoCD                                         |
|----------------------------|-----------------------------------------------|------------------------------------------------|
| Architecture               | Decentralised controllers (no server)         | Centralised server + API + UI                  |
| Web UI                     | None built-in (Weave GitOps available)        | Built-in (excellent)                           |
| CLI                        | `flux` CLI                                    | `argocd` CLI                                   |
| Helm support               | `HelmRelease` CRD                             | Native Helm rendering                          |
| Kustomize support          | `Kustomization` CRD (native)                  | Native                                         |
| Image automation           | Built-in (image-reflector + automation)        | Separate tool (ArgoCD Image Updater)           |
| Multi-tenancy              | Kubernetes RBAC + tenant isolation            | AppProject RBAC + ArgoCD-specific RBAC         |
| Bootstrap                  | `flux bootstrap` = fully GitOps from start    | Install then configure via UI/manifests        |
| Drift detection            | Continuous reconciliation every interval      | Continuous reconciliation                      |
| Notification               | notification-controller CRD                   | notification-controller + UI                   |
| OCI support                | Native (GitRepository, HelmRepository as OCI) | OCI as Helm repo only                         |
| Learning curve             | Higher (more CRDs, more controllers)          | Lower (UI lowers barrier to entry)             |
| CNCF status                | Graduated                                     | Graduated                                      |
| Best for                   | Kubernetes-native teams, image automation     | Teams wanting a platform dashboard, multi-cluster |

---

## Useful Flux CLI Commands

```bash
# Check Flux component health
flux check

# List all Flux resources
flux get all -n flux-system

# Force reconcile a GitRepository (pull latest from Git now)
flux reconcile source git kube-platform -n flux-system

# Force reconcile a Kustomization
flux reconcile kustomization apps -n flux-system

# Force reconcile a HelmRelease
flux reconcile helmrelease apache -n webapps

# View events for a resource
flux events --for GitRepository/kube-platform -n flux-system

# Suspend reconciliation (for maintenance)
flux suspend kustomization apps -n flux-system

# Resume reconciliation
flux resume kustomization apps -n flux-system

# Export all Flux resources as YAML
flux export source git kube-platform -n flux-system

# View logs from Flux controllers
flux logs --all-namespaces --follow

# Uninstall Flux (does NOT delete managed resources)
flux uninstall --namespace flux-system
```
