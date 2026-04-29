# Contributing to kube-platform

Thank you for contributing to this production Kubernetes reference repository. Every example here is intended to be safe to learn from and safe to adapt for real clusters. Please read this guide fully before submitting a pull request.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Repository Structure](#repository-structure)
- [Adding a New Example](#adding-a-new-example)
- [Coding Standards](#coding-standards)
  - [Naming Conventions](#naming-conventions)
  - [Label Requirements](#label-requirements)
  - [Security Requirements](#security-requirements)
  - [Resource Requirements](#resource-requirements)
- [Pull Request Checklist](#pull-request-checklist)
- [Running Tests Locally](#running-tests-locally)

---

## Prerequisites

Before contributing, ensure the following tools are installed and available on your `PATH`.

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| `kind` | 0.29.0 | `brew install kind` / see `setup/local/kind/install.sh` |
| `kubectl` | 1.30.0 | `brew install kubectl` |
| `helm` | 3.17.0 | `brew install helm` |
| `yamllint` | 1.35.0 | `pip install yamllint` |
| `kubeval` | 0.16.1 | `brew install kubeval` |
| `kubeconform` | 0.6.7 | `brew install kubeconform` |
| `docker` | 24.0+ | [docker.com](https://docs.docker.com/get-docker/) |
| `make` | 3.81+ | Included on macOS/Linux |

Verify everything is ready:

```bash
kind version
kubectl version --client
helm version
yamllint --version
kubeconform -v
```

---

## Repository Structure

```
.
├── setup/          # Cluster provisioning (KIND, Minikube, kubeadm, EKS)
├── workloads/      # Core Kubernetes workload objects
├── networking/     # Services, Ingress, NetworkPolicies
├── storage/        # PV, PVC, StorageClass
├── security/       # RBAC, Kyverno policies
├── helm/           # Helm chart examples
├── observability/  # Prometheus, Grafana
├── gitops/         # Argo CD manifests
└── sealed-secrets/ # Encrypted Secrets for GitOps
```

Each subdirectory should be self-contained: a reader should be able to understand and apply the manifests without reading the rest of the repository.

---

## Adding a New Example

Follow these steps to add a new concept or workload example.

### Step 1 — Pick the right directory

Place your files under the most specific matching directory. If none exists, create a new one following the existing naming pattern (kebab-case, noun-first).

### Step 2 — Required files

Every new example **must** include:

| File | Purpose |
|------|---------|
| `README.md` | Explains the concept, what each file does, and how to apply it |
| At least one `.yaml` manifest | The actual Kubernetes object(s) |

Optional but encouraged:

- A cleanup section in the README (`kubectl delete -f .`)
- A note on which Kubernetes version the example was validated against

### Step 3 — Validate before committing

```bash
# Lint all YAML
make lint

# Validate manifests against the Kubernetes schema
make validate

# Lint Helm charts (if applicable)
make helm-lint

# Run everything at once
make check
```

### Step 4 — Apply to a local cluster and verify

```bash
make cluster-up
kubectl apply -f <your-directory>/
kubectl get all -n <namespace>
```

Do not commit manifests that you have not applied at least once to a real cluster.

---

## Coding Standards

### Naming Conventions

- Resource names: `kebab-case`, descriptive, noun-first (e.g., `nginx-deployment`, `mysql-configmap`).
- Namespaces: one namespace per application family (e.g., `nginx`, `mysql`, `monitoring`).
- File names: match the resource kind in lowercase kebab-case. One resource per file unless the resources are tightly coupled (e.g., a Role and its RoleBinding).
  - `deployment.yaml`, `service.yaml`, `configmap.yaml`, `secret.yaml`
- ConfigMap keys: `snake_case` for structured data, `kebab-case` for filenames mounted into containers.

### Label Requirements

Every Kubernetes object **must** carry the full `app.kubernetes.io/*` label set. No exceptions.

```yaml
labels:
  app.kubernetes.io/name: <app-name>
  app.kubernetes.io/instance: <app-name>
  app.kubernetes.io/version: "1.0.0"
  app.kubernetes.io/component: <component-role>   # e.g. frontend, backend, database, cache
  app.kubernetes.io/part-of: kube-platform
  app.kubernetes.io/managed-by: kubectl
```

Every object **must** also include the description annotation:

```yaml
annotations:
  kubernetes.io/description: "One sentence describing what this object does."
```

### Security Requirements

All Pod specs **must** include the following. PRs that omit any of these fields will be rejected.

**Pod-level `securityContext`:**

```yaml
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 60
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
    seccompProfile:
      type: RuntimeDefault
```

**Container-level `securityContext`:**

```yaml
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

**Lifecycle hook** (prevents lost in-flight requests during rolling updates):

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]
```

**Rationale:**
- `runAsNonRoot` / `runAsUser: 1000`: prevents root exploitation.
- `readOnlyRootFilesystem`: forces explicit `emptyDir` or volume mounts for writable paths, reducing attack surface.
- `allowPrivilegeEscalation: false`: prevents `sudo`/`setuid` abuse.
- `capabilities: drop: ["ALL"]`: removes all Linux capabilities; add back only what is strictly required.
- `seccompProfile: RuntimeDefault`: applies the container runtime's default syscall filter.
- `automountServiceAccountToken: false`: prevents unintended API server access.

### Resource Requirements

- All containers **must** define `resources.requests.memory` and `resources.limits.memory`.
- Memory requests **must equal** memory limits (Guaranteed QoS class, prevents OOM eviction surprises).
- CPU requests should be set; CPU limits are **intentionally omitted** for most workloads to avoid artificial throttling.
- Use `imagePullPolicy: IfNotPresent` for versioned tags. Use `Always` only for `:latest` (discouraged).

```yaml
resources:
  requests:
    memory: "128Mi"
    cpu: "100m"
  limits:
    memory: "128Mi"   # must equal request
    # cpu limit omitted intentionally
```

### Deployment Standards

```yaml
spec:
  revisionHistoryLimit: 5
  minReadySeconds: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

---

## Pull Request Checklist

Before marking your PR as ready for review, confirm every item below.

- [ ] `make check` passes locally with zero errors.
- [ ] Every Kubernetes object has the full `app.kubernetes.io/*` label set.
- [ ] Every Kubernetes object has a `kubernetes.io/description` annotation.
- [ ] All pod specs include the required `securityContext` at both pod and container level.
- [ ] All containers include the `preStop` lifecycle hook.
- [ ] Memory request equals memory limit in all containers.
- [ ] No secrets, credentials, kubeconfig files, or `.env` files are committed.
- [ ] A `README.md` exists for the new example explaining what it demonstrates.
- [ ] The manifests have been applied to a local cluster and verified working.
- [ ] File names are in kebab-case and match the resource kind.
- [ ] The PR description explains *why* the example is useful, not just *what* it contains.
- [ ] PR title follows the format: `feat(scope): short description` or `fix(scope): short description`.

---

## Running Tests Locally

```bash
# Install yamllint (one time)
pip install yamllint

# Run yamllint only
make lint

# Run kubeval schema validation only
make validate

# Run helm lint only
make helm-lint

# Run all checks (lint + validate + helm-lint)
make check

# Create a local KIND cluster and apply all examples end-to-end
make cluster-up
make apply-nginx
make apply-mysql
make apply-rbac
make apply-network-policies

# Tear everything down
make teardown
```

If any check fails, fix the issue before pushing. The CI pipeline runs the same `make check` sequence and will block merging on failure.

---

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/) Code of Conduct. Be respectful, constructive, and collaborative.
