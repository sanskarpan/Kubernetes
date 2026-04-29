# GitOps

## What Is GitOps?

GitOps is an operational framework that takes DevOps best practices used for application
development — version control, collaboration, compliance, CI/CD — and applies them to
infrastructure automation.

**Core principle: Git is the single source of truth for the desired state of your system.**

The GitOps loop:
1. Developers commit desired state to Git (manifests, Helm values, Kustomize overlays)
2. A GitOps operator (ArgoCD, Flux) detects the change
3. The operator reconciles the cluster state to match Git
4. If cluster state drifts from Git (manual `kubectl apply`), the operator corrects it

Benefits:
- Full audit trail — every change is a Git commit with author, timestamp, and reason
- Rollback = `git revert` (fast and reliable)
- Disaster recovery — any cluster can be rebuilt by pointing the GitOps operator at the repo
- Separation of concerns — developers push to Git; operators never touch production directly
- Pull-based security — the cluster pulls changes; no inbound firewall rules needed for CD

---

## Push-Based vs Pull-Based Deployment

| Aspect              | Push-Based (traditional CI/CD)          | Pull-Based (GitOps)                     |
|---------------------|-----------------------------------------|-----------------------------------------|
| Trigger             | CI pipeline pushes changes              | In-cluster operator polls Git           |
| Cluster access      | CI server needs cluster credentials     | Cluster pulls; no external access needed|
| Drift detection     | None — drift goes unnoticed             | Continuous — drift is detected and healed|
| Audit trail         | CI logs (may be purged)                 | Git history (immutable)                 |
| Rollback            | Re-run pipeline with old image tag      | `git revert` + auto-sync               |
| Secrets handling    | CI env vars / vault integration         | External Secrets Operator + Vault       |
| Multi-cluster       | Credentials per cluster in CI           | One operator instance per cluster       |
| Complexity          | Lower initial setup                     | Higher initial setup, lower operational |

**Recommendation:** Use GitOps (pull-based) for production. Use push-based for dev/preview
environments where speed matters more than auditability.

---

## ArgoCD vs Flux Comparison

| Feature                    | ArgoCD                                    | Flux                                       |
|----------------------------|-------------------------------------------|--------------------------------------------|
| Architecture               | Server + controller + UI                  | Set of controllers (no separate UI)        |
| UI                         | Built-in web UI + CLI                     | CLI only (Weave GitOps for UI)             |
| Sync model                 | App-of-Apps, ApplicationSets              | Kustomization + HelmRelease CRDs           |
| Helm support               | Native (renders and applies)              | Native via HelmRelease CRD                 |
| Kustomize support          | Native                                    | Native                                     |
| Multi-tenancy              | AppProject RBAC                           | Multi-tenancy via tenants                  |
| Image automation           | Separate ArgoCD Image Updater             | Built-in image reflector + automation      |
| Notification               | Notification controller                   | Notification controller                    |
| RBAC                       | ArgoCD-specific RBAC + SSO                | Kubernetes RBAC                            |
| Learning curve             | Lower (great UI, clear concepts)          | Higher (more CRDs, more composable)        |
| Community                  | CNCF graduated, large community           | CNCF graduated, large community            |
| Best for                   | Teams wanting a full GitOps platform      | Teams preferring Kubernetes-native tooling |

### When to Use ArgoCD

- You want a visual dashboard to see sync status across applications
- Your team is new to GitOps and benefits from the UI
- You need multi-tenancy with AppProject scoping
- You have complex multi-cluster deployments (ArgoCD manages multiple remote clusters)

### When to Use Flux

- You prefer pure Kubernetes RBAC (no ArgoCD-specific RBAC layer)
- You need built-in image automation (update manifests when new images are pushed)
- You want a fully declarative bootstrap (the bootstrap process itself is GitOps)
- You use Kustomize heavily and want native Kustomization CRD control

---

## App-of-Apps Pattern (ArgoCD)

The App-of-Apps pattern uses one "root" ArgoCD Application to manage all other Applications.
This enables bootstrapping an entire cluster from a single `kubectl apply`.

```
gitops/argocd/
├── app-of-apps.yml          ← Root Application (deploy this once)
└── apps/
    ├── apache.yml           ← Application for the Apache chart
    ├── node-app.yml         ← Application for the node-app chart
    └── monitoring.yml       ← Application for the Prometheus stack
```

Bootstrap sequence:
```bash
# 1. Install ArgoCD
kubectl apply -k https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Apply the root Application only — ArgoCD manages everything else
kubectl apply -f gitops/argocd/app-of-apps.yml -n argocd
```

ArgoCD then automatically creates and syncs all child Applications.

---

## Multi-Cluster GitOps

### ArgoCD Multi-Cluster

ArgoCD runs in one "hub" cluster and deploys to many "spoke" clusters:

```bash
# Add a spoke cluster to ArgoCD
argocd cluster add my-spoke-cluster --name production-eu

# Applications can target any registered cluster
# destination:
#   server: https://my-spoke-cluster-api.example.com
#   namespace: apps
```

### Flux Multi-Cluster

Each cluster runs its own Flux controllers, all pointing at the same Git repository but
reading different paths:

```
gitops/
├── clusters/
│   ├── production-us/    ← Flux in prod-us reads this path
│   │   └── kustomization.yaml
│   └── production-eu/    ← Flux in prod-eu reads this path
│       └── kustomization.yaml
└── apps/                 ← Shared app definitions referenced by both clusters
    ├── apache/
    └── node-app/
```

---

## Repository Structure for GitOps

This repository follows the following GitOps layout:

```
gitops/
├── README.md                   ← This file
├── argocd/
│   ├── install.md              ← ArgoCD installation guide
│   ├── app-of-apps.yml         ← Root Application (bootstrap entry point)
│   ├── app-project.yml         ← AppProject for RBAC scoping
│   └── apps/                   ← Child Application manifests (one per service)
└── flux/
    └── README.md               ← Flux installation and usage guide
```
