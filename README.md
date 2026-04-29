# Kubernetes Production Reference Repository

[![Validate YAML](https://github.com/your-org/kube-platform/actions/workflows/validate-yaml.yml/badge.svg)](https://github.com/your-org/kube-platform/actions/workflows/validate-yaml.yml)
[![Helm Lint](https://github.com/your-org/kube-platform/actions/workflows/helm-lint.yml/badge.svg)](https://github.com/your-org/kube-platform/actions/workflows/helm-lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Kubernetes: 1.29 | 1.30 | 1.31 | 1.32](https://img.shields.io/badge/Kubernetes-1.29%20%7C%201.30%20%7C%201.31%20%7C%201.32-blue?logo=kubernetes)](https://kubernetes.io/releases/)
[![KIND: 0.29.0](https://img.shields.io/badge/KIND-0.29.0-blue)](https://kind.sigs.k8s.io/)

A production-grade Kubernetes reference repository covering cluster setup, workload manifests, networking, storage, security, observability, GitOps, and platform tooling. Every manifest in this repository follows real-world best practices: non-root containers, read-only root filesystems, resource limits, security contexts, and structured labels.

---

## Learning Path

Work through the tracks in order. Each track builds on the previous.

| Track | Audience | Topics | Directory |
|-------|----------|--------|-----------|
| **Beginner** | New to Kubernetes | Cluster setup, Pods, Deployments, Services, ConfigMaps, Secrets | `setup/`, `workloads/`, `networking/services/` |
| **Intermediate** | Comfortable with kubectl | Ingress, RBAC, Persistent Volumes, StatefulSets, Jobs, CronJobs, HPA | `networking/ingress/`, `security/rbac/`, `storage/`, `workloads/` |
| **Advanced** | Production operators | Network Policies, OPA/Kyverno, Sealed Secrets, Helm, GitOps/Argo CD, Observability | `security/network-policies/`, `helm/`, `gitops/`, `observability/` |

---

## Quick Start

### Option A — Automated bootstrap (recommended)

```bash
# Clone the repo
git clone https://github.com/your-org/kube-platform.git
cd kube-platform

# One command: installs KIND, creates cluster, deploys core workloads
make bootstrap
```

### Option B — Manual KIND cluster

```bash
# 1. Install KIND (macOS)
brew install kind

# 2. Create the cluster using the provided config
kind create cluster --name kube-platform --config setup/local/kind/kind-config.yml

# 3. Verify
kubectl cluster-info --context kind-kube-platform
kubectl get nodes

# 4. Apply example workloads
make apply-nginx
make apply-mysql
```

### Option C — Minikube

```bash
minikube start --cpus 4 --memory 8192 --kubernetes-version v1.32.0
minikube addons enable ingress metrics-server dashboard
```

---

## Directory Tree

```
.
├── Makefile
├── README.md
├── CONTRIBUTING.md
├── .gitignore
├── .github/
│   └── workflows/
│       ├── validate-yaml.yml
│       └── helm-lint.yml
│
├── setup/
│   ├── README.md                        # Cluster setup comparison guide
│   ├── local/
│   │   ├── kind/
│   │   │   ├── README.md
│   │   │   ├── install.sh               # Idempotent KIND + kubectl installer
│   │   │   └── kind-config.yml          # 1 control-plane + 2 workers
│   │   └── minikube/
│   │       └── README.md
│   ├── cloud/
│   │   └── eks/
│   │       └── README.md                # eksctl-based EKS setup
│   └── kubeadm/
│       ├── README.md
│       ├── 00-common.sh                 # Runs on all nodes
│       ├── 01-master.sh                 # Control-plane init + Calico
│       └── 02-worker.sh                 # Worker join
│
├── workloads/
│   ├── nginx/
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── mysql/
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── secret.yaml
│   ├── jobs/
│   │   ├── job.yaml
│   │   └── cronjob.yaml
│   └── statefulset/
│       ├── statefulset.yaml
│       └── headless-service.yaml
│
├── networking/
│   ├── services/
│   │   ├── clusterip.yaml
│   │   ├── nodeport.yaml
│   │   └── loadbalancer.yaml
│   ├── ingress/
│   │   ├── nginx-ingress-controller.yaml
│   │   └── ingress.yaml
│   └── network-policies/
│       ├── default-deny-all.yaml
│       ├── allow-same-namespace.yaml
│       └── allow-ingress-to-app.yaml
│
├── storage/
│   ├── pv.yaml
│   ├── pvc.yaml
│   └── storageclass.yaml
│
├── security/
│   ├── rbac/
│   │   ├── serviceaccount.yaml
│   │   ├── role.yaml
│   │   ├── rolebinding.yaml
│   │   ├── clusterrole.yaml
│   │   └── clusterrolebinding.yaml
│   ├── network-policies/
│   │   └── (see networking/network-policies/)
│   └── kyverno/
│       ├── require-labels.yaml
│       ├── disallow-privileged.yaml
│       └── require-resource-limits.yaml
│
├── helm/
│   ├── apache/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   └── node-app/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│
├── observability/
│   ├── prometheus/
│   │   └── values.yaml                  # kube-prometheus-stack Helm values
│   └── grafana/
│       └── dashboards/
│
├── gitops/
│   └── argocd/
│       ├── install.yaml
│       └── app-of-apps.yaml
│
└── sealed-secrets/
    ├── README.md
    └── example-sealed-secret.yaml
```

---

## Kubernetes Concepts Coverage

| Concept | Kind | File(s) |
|---------|------|---------|
| Pod | Pod | `workloads/nginx/deployment.yaml` |
| Deployment | Deployment | `workloads/nginx/deployment.yaml`, `workloads/mysql/deployment.yaml` |
| StatefulSet | StatefulSet | `workloads/statefulset/statefulset.yaml` |
| DaemonSet | DaemonSet | `observability/prometheus/` |
| Job | Job | `workloads/jobs/job.yaml` |
| CronJob | CronJob | `workloads/jobs/cronjob.yaml` |
| ConfigMap | ConfigMap | `workloads/mysql/configmap.yaml` |
| Secret | Secret | `workloads/mysql/secret.yaml` |
| Service (ClusterIP) | Service | `networking/services/clusterip.yaml` |
| Service (NodePort) | Service | `networking/services/nodeport.yaml` |
| Service (LoadBalancer) | Service | `networking/services/loadbalancer.yaml` |
| Ingress | Ingress | `networking/ingress/ingress.yaml` |
| IngressClass | IngressClass | `networking/ingress/nginx-ingress-controller.yaml` |
| PersistentVolume | PV | `storage/pv.yaml` |
| PersistentVolumeClaim | PVC | `storage/pvc.yaml` |
| StorageClass | StorageClass | `storage/storageclass.yaml` |
| Namespace | Namespace | `workloads/*/namespace.yaml` |
| ServiceAccount | ServiceAccount | `security/rbac/serviceaccount.yaml` |
| Role | Role | `security/rbac/role.yaml` |
| RoleBinding | RoleBinding | `security/rbac/rolebinding.yaml` |
| ClusterRole | ClusterRole | `security/rbac/clusterrole.yaml` |
| ClusterRoleBinding | ClusterRoleBinding | `security/rbac/clusterrolebinding.yaml` |
| NetworkPolicy | NetworkPolicy | `networking/network-policies/` |
| HorizontalPodAutoscaler | HPA | `workloads/nginx/` |
| ResourceQuota | ResourceQuota | `workloads/*/namespace.yaml` |
| LimitRange | LimitRange | `workloads/*/namespace.yaml` |
| Helm Chart | — | `helm/apache/`, `helm/node-app/` |
| Kyverno Policy | ClusterPolicy | `security/kyverno/` |
| Argo CD Application | Application | `gitops/argocd/` |
| SealedSecret | SealedSecret | `sealed-secrets/` |

---

## Interview-Ready Concepts

Use this table to navigate to the exact files that demonstrate the concept an interviewer is likely to test.

| Interview Topic | Key Files |
|----------------|-----------|
| How does a Pod get scheduled? | `workloads/nginx/deployment.yaml` — see `nodeSelector`, `affinity`, `tolerations` |
| Rolling update strategy | `workloads/nginx/deployment.yaml` — `strategy.rollingUpdate` |
| Liveness vs Readiness probes | `workloads/nginx/deployment.yaml` — `livenessProbe`, `readinessProbe` |
| How Ingress works | `networking/ingress/ingress.yaml`, `nginx-ingress-controller.yaml` |
| RBAC model | `security/rbac/` — all five objects |
| Network Policies (default deny) | `networking/network-policies/default-deny-all.yaml` |
| Persistent storage lifecycle | `storage/pv.yaml`, `storage/pvc.yaml`, `storage/storageclass.yaml` |
| StatefulSet vs Deployment | `workloads/statefulset/statefulset.yaml` |
| Jobs and CronJobs | `workloads/jobs/` |
| Secrets management (GitOps-safe) | `sealed-secrets/` |
| Pod Security Standards | `security/kyverno/disallow-privileged.yaml` |
| HPA + metrics-server | `workloads/nginx/` |
| Resource limits and QoS | Memory request == limit (Guaranteed QoS) in every manifest |
| KIND cluster creation | `setup/local/kind/` |
| Kubeadm cluster creation | `setup/kubeadm/` |
| EKS cluster creation | `setup/cloud/eks/README.md` |
| Helm packaging | `helm/` |
| GitOps with Argo CD | `gitops/argocd/` |
| Policy enforcement (OPA/Kyverno) | `security/kyverno/` |
| Observability stack | `observability/prometheus/` |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines. The short version:

1. Fork the repository and create a feature branch.
2. Add your example under the appropriate directory.
3. Include a `README.md` explaining the concept.
4. Ensure all manifests follow the label and security-context standards documented in `CONTRIBUTING.md`.
5. Run `make check` locally — CI will enforce the same checks.
6. Open a pull request against `main`.

---

## License

This project is licensed under the [MIT License](LICENSE).

Copyright (c) 2024 kube-platform contributors.
