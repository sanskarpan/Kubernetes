# Kubernetes Platform Architecture Audit & Unified Codebase Design

**Date:** 2026-04-27
**Author:** Claude (Senior Staff-level Platform Engineer)
**Scope:** Deep architectural audit of two Kubernetes repositories + unified production-grade codebase design

---

## Repositories Analyzed

1. `LondheShubham153/kubernetes-in-one-shot` (branch: `master`)
2. `LondheShubham153/kubestarter` (branch: `main`)

---

## Phase 1 — Deep Repo Dissection

### Repo 1: `kubernetes-in-one-shot`

#### File Tree

```
README.md
apache/
  deployment.yml, hpa.yml, namespace.yml, role-binding.yml, role.yml
  service-account.yml, service.yml, vpa.yml
crd/
  devops-cr.yml, devops-cr2.yml, devops-crd.yml
dashboard/
  dashboard-admin-user.yml
django-notes-app/
  Dockerfile, Jenkinsfile, docker-compose.yml, manage.py, requirements.txt
  k8s/ (deployment.yml, hpa.yml, namespace.yml, service.yml)
  mynotes/ (React frontend)
  notesapp/ (Django backend)
helm/
  get_helm.sh, apache-helm-0.1.0.tgz, node-js-app-0.1.0.tgz
  apache-helm/ (full chart: Chart.yaml, values.yaml, templates/)
  node-js-app/ (full chart: Chart.yaml, values.yaml, templates/)
monitoring/
  get_helm.sh (DUPLICATE of helm/get_helm.sh)
mysql/
  configMap.yml, namespace.yml, secrets.yml, service.yml
  statefulset.yml, vpa.yml
nginx/
  cron-job.yml, daemonsets.yml, deployment.yml, ingress.yml, job.yml
  namespace.yml, persistentVolume.yml, persistentVolumeClaim.yml
  pod.yml, replicasets.yml, service.yml
pods/
  init-container.yml, sidecar-container.yml
```

#### 1. Structural Design

Flat, per-workload directories — each technology gets its own folder (`apache/`, `nginx/`, `mysql/`, `pods/`). No environment abstraction, no base/overlay separation, no shared library concept. Naming conventions are inconsistent: some files use camelCase (`configMap.yml`), others use kebab-case (`role-binding.yml`), and YAML extensions mix `.yml` and `.yaml`.

The separation of concerns is **technology-driven, not concern-driven**. Everything related to Apache lives in `apache/` — deployment, service, HPA, VPA, Role, RoleBinding, ServiceAccount. Convenient for copy-paste demos but creates a structural problem at scale: there is no canonical location for "all RBAC resources" or "all HPA resources" across the cluster.

Helm charts are committed as both source (`apache-helm/`) and as `.tgz` archives — an anti-pattern. Compiled artifacts drift from source, and the repo bloats with binary blobs.

Reusability is low. No Kustomize bases, no shared values files, no templating for environment differentiation.

#### 2. Content Type Analysis

**YAML-first, documentation-light.** The README serves as both a command cheat sheet and an index. Excellent for quick lookup, provides no conceptual scaffolding for learners.

Notable strengths:
- Working YAML manifests with resource requests/limits — most tutorial repos skip this
- HPA using `autoscaling/v2` — current API version, not deprecated v1
- VPA examples — rare in tutorial repos
- StatefulSet with `volumeClaimTemplates` — correct pattern for stateful workloads
- CRD + Custom Resource — demonstrates API extensibility
- Sidecar and init container patterns — operationally important patterns rarely taught
- Jenkinsfile — actual CI/CD pipeline definition
- Full Helm charts with HPA, Ingress, ServiceAccount, test hooks

Orientation: **learning + reference.** Files are correct enough to run but not production-hardened.

#### 3. Coverage Mapping

| Domain | Coverage | Quality |
|---|---|---|
| Cluster setup (kind/minikube/kubeadm/EKS) | None | N/A |
| Pods / Init / Sidecar | Yes | Good |
| Deployments | Yes | Good |
| ReplicaSets | Yes | Redundant given Deployments |
| StatefulSets | Yes (MySQL) | Good |
| DaemonSets | Yes | Minimal |
| Jobs / CronJobs | Yes | Good |
| Services (ClusterIP/NodePort/LB) | Partial (ClusterIP only) | Weak |
| Ingress | Yes (path-based routing) | Good |
| Network Policies | No | Gap |
| PV / PVC / StorageClass | Yes (hostPath only) | Basic |
| ConfigMaps / Secrets | Yes (ref in env) | Good |
| HPA | Yes (v2 API) | Good |
| VPA | Yes | Good (has capitalization bug) |
| RBAC | Yes (Role + RoleBinding + SA) | Good |
| CRDs | Yes (course-branded) | Unique |
| Helm | Yes (2 complete charts) | Strong |
| Monitoring | Reference only | Weak |
| CI/CD | Jenkinsfile | Minimal |

#### 4. Developer Experience

- **Onboarding friction: High** — no setup instructions, no learning path
- **Copy-paste usability: High** — individual YAMLs are self-contained
- **Clarity of documentation: Low** — README is a command list, not a guide
- **Learning curve: Steep** — assumes prior Kubernetes knowledge

#### 5. Production Readiness Score

| Criterion | Score | Notes |
|---|---|---|
| Modularity | 3/10 | Flat dirs, no base/overlay |
| Idempotency | 7/10 | `kubectl apply` is idempotent |
| Environment separation | 0/10 | No dev/staging/prod concept |
| Secrets handling | 2/10 | Base64 in manifest, hardcoded |
| Scalability patterns | 6/10 | HPA + VPA present |
| Resource governance | 6/10 | requests/limits on most workloads |
| Observability | 1/10 | Referenced but not implemented |
| Security posture | 3/10 | RBAC present, no PSS/PSA, no network policies |

#### Confirmed Bugs

| File | Bug | Impact |
|---|---|---|
| `mysql/vpa.yml` | kind is `VerticalPodAutoScaler` (capital S, wrong) | API server rejects this object |
| `mysql/statefulset.yml` | memory limit (25Mi) is lower than request (128Mi) | Scheduler rejects pod |
| `helm/node-js-app/values.yaml` | `tartgetPort` typo | Helm template references nonexistent key |
| `monitoring/get_helm.sh` | Byte-for-byte duplicate of `helm/get_helm.sh` | Maintenance drift risk |

---

### Repo 2: `kubestarter`

#### File Tree

```
README.md
kubernetes_architecture.md
minikube_installation.md
Minikube_Windows_Installation.md
eks_cluster_setup.md
ci_cd_with_kubernetes.md
DaemonSet/
  README.md, daemonset-deploy.yaml
Deployment_Strategies/
  README.md, deployment-strategies-comparison.md, kind-config.yml
  Blue-green-deployment/ (README.md, blue-green-ns.yml, 2 deployment+service YAMLs)
  Canary-deployment/ (README.md, namespace, combined service, v1/v2 deployments, ingress)
  Recreate-deployment/ (README.md, namespace, deployment, service)
  Rolling-Update-Deployment/ (README.md, namespace, deployment, service)
  Simple-Canary-Example/ (README.md, namespace, 2 configmaps, 2 deployments, service, ingress)
HELM/
  README.md, get_helm.sh
  apache/ (full chart: Chart.yaml, values.yaml, templates/)
HPA_VPA/
  README.md, apache-deployment.yml, apache-hpa.yml, apache-vpa.yml
Ingress/
  README.md, apache.yml, nginx.yml, ingress.yml
Kubeadm_Installation_Scripts_and_Documentation/
  README.md
  Kubeadm_Installation_Common_Using_Containerd.sh
  Kubeadm_Installation_Master_Using_Containerd.sh
  Kubeadm_Installation_Slave_Using_Containerd.sh
PersistentVolumes/
  README.md, PersistentVolume.yaml, PersistentVolumeClaim.yaml, Pod.yaml
RBAC/
  README.md, namespace.yml, apache-deployment.yml, apache-role.yml
  apache-rolebinding.yml, apache-serviceaccount.yml
Taints-and-Tolerations/
  README.md, pod.yml
examples/
  More_K8s_Practice_Ideas.md
  helm/ (README.md, node-app/ chart)
  mysql/ (README.md, configMap.yml, deployment.yml, persistentVols.yml, secrets.yml)
  nginx/ (README.md, pod.yml, deployment.yml, service.yml)
kind-cluster/
  README.md, install.sh, kind-config.yml, dashboard-admin-user.yml
projectGuide/
  easyshop-kind.md, online-shop.md
```

#### 1. Structural Design

**Concern-based directories** — `Deployment_Strategies/`, `HPA_VPA/`, `RBAC/`, `Ingress/`, etc. This is more aligned with how a practitioner thinks ("I need to understand HPA") than with how applications are deployed.

Naming conventions are inconsistent across the repo: `kubeadm_Installation_...` (snake_case), `Blue-green-deployment` (mixed), `kind-cluster` (kebab), `HELM` (uppercase) — signals organic growth without a consistent standard.

`examples/` functions as a catch-all that partially overlaps with top-level directories. The `HELM/` directory has an Apache chart and `examples/helm/` has a Node.js chart with no cross-referencing.

Reusability is slightly better — Kubeadm scripts are split into Common/Master/Worker, which is the correct split for automation. But they are not parameterized (hardcoded Kubernetes version, CNI URL, containerd config path).

#### 2. Content Type Analysis

**Documentation-first, YAML-second.** Almost every directory has a `README.md` explaining the concept, providing deployment steps, and linking to commands. This is the repo's primary strength.

Notable strengths:
- Architecture guide with analogies for each K8s component
- Deployment strategies comparison — the most complete treatment in any tutorial repo
- Four complete deployment strategy implementations with working YAMLs
- Three-script Kubeadm setup (Common/Master/Worker) with containerd, SystemdCgroup, Calico CNI
- KIND cluster with port mapping — correct for local development
- EKS setup guide with eksctl — cloud-ready
- Project guides for real applications (EasyShop, Online Shop)

Orientation: **learning-first, production-adjacent.** Strong pedagogically. Deployment strategies section is the best standalone resource for this topic in any tutorial-style repo.

#### 3. Coverage Mapping

| Domain | Coverage | Quality |
|---|---|---|
| Cluster setup — KIND | Yes (with port mapping) | Strong |
| Cluster setup — Minikube | Yes (Ubuntu + Windows) | Good |
| Cluster setup — Kubeadm | Yes (3-script split) | Strong |
| Cluster setup — EKS | Yes (eksctl) | Good |
| Architecture concepts | Yes | Excellent (analogies) |
| Pods | Basic (in examples/) | Minimal |
| Deployments | Yes | Good |
| DaemonSets | Yes (with use cases) | Good |
| StatefulSets | No (MySQL uses Deployment — wrong) | Gap |
| Jobs / CronJobs | No | Gap |
| Sidecar / Init containers | No | Gap |
| Services | Partial (ClusterIP + NodePort) | Basic |
| Ingress | Yes (multi-path) | Good |
| Network Policies | No | Gap |
| PV / PVC | Yes | Good |
| ConfigMaps / Secrets | Yes | Good |
| HPA | Yes (v2 API) | Good |
| VPA | Yes | Good |
| RBAC | Yes (namespace-scoped only) | Good |
| CRDs | No | Gap |
| Taints / Tolerations | Yes | Good |
| Helm | Yes (2 charts) | Good |
| Deployment Strategies | Yes (all 4) | Excellent |
| CI/CD concepts | Yes (doc only) | Weak on implementation |
| Monitoring | No | Gap |

#### 4. Developer Experience

- **Onboarding friction: Low** — architecture → setup → primitives → advanced is clear
- **Copy-paste usability: High** — every directory has a README with exact commands
- **Clarity of documentation: High** — concepts explained with analogies before YAML
- **Learning curve: Gentle slope** — well-designed pedagogical progression

#### 5. Production Readiness Score

| Criterion | Score | Notes |
|---|---|---|
| Modularity | 4/10 | Per-concept dirs, no base/overlay |
| Idempotency | 6/10 | KIND install.sh uses `command -v` checks |
| Environment separation | 0/10 | No dev/staging/prod concept |
| Secrets handling | 2/10 | Base64 in Secret manifest |
| Scalability patterns | 6/10 | HPA + VPA present |
| Resource governance | 5/10 | Present in some, absent in others |
| Observability | 0/10 | Not addressed |
| Security posture | 3/10 | RBAC present, no network policy, no PSS |

#### Key Issues

- MySQL uses `Deployment` for a stateful database — architecturally incorrect. MySQL requires `StatefulSet` with `volumeClaimTemplates` for stable network identity and ordered scaling.
- Kubernetes version references are inconsistent: v1.29 (kubeadm), v1.33.1 (deployment strategies kind-config), v1.35.0 (kind-cluster) — different sections written at different times without version governance.
- MySQL secret stores literal string `trainwithshubham` in base64 — pedagogically problematic without explicit warning.
- Helm charts duplicated across `HELM/apache/` and `examples/helm/node-app/` with no cross-referencing.

---

## Phase 2 — Comparative Analysis

| Dimension | Repo 1 | Repo 2 | Winner | Reasoning |
|---|---|---|---|---|
| Learning effectiveness | Low — no explanations, pure reference | High — architecture docs, analogies, progressive path | Repo 2 | Repo 1 is a lookup tool, not a teaching tool |
| Real-world usability | Medium — YAMLs runnable, resource limits, edge cases | Medium — good examples but MySQL-as-Deployment is wrong | Repo 1 | StatefulSet, VolumeClaimTemplates, init/sidecar containers, CRD |
| Reusability | Low — flat dirs, no templating | Low — same issue, slightly better doc separation | Tie | Neither implements Kustomize, Helm overlays, or environment separation |
| Maintainability | Poor — bugs present, duplicated files, binary blobs | Fair — cleaner structure, version drift across scripts | Repo 2 | Fewer bugs and better structural discipline |
| Production readiness | Low — no cluster setup, no env separation | Low — same secrets issue, wrong StatefulSet pattern | Tie | Both are teaching repos, neither is production-grade |
| Extensibility | Low — new workload = new flat directory | Medium — per-concept structure makes adding new concepts straightforward | Repo 2 | Adding a strategy means adding a folder under Deployment_Strategies/ |
| Cluster setup coverage | None | Excellent (minikube/kind/kubeadm/EKS) | Repo 2 | Repo 1 doesn't tell you how to create a cluster |
| YAML correctness | Poor — three reject-worthy manifests | Fair — MySQL architecture wrong but no syntax bugs | Repo 2 | Repo 1 has scheduler-rejected manifests |
| Advanced feature depth | High — VPA, CRD, sidecar, init, Helm, StatefulSet | Medium — strong on strategies, weak on advanced primitives | Repo 1 | Covers more of the Kubernetes surface area at API level |
| CI/CD implementation | Concrete (Jenkinsfile) | Conceptual only (docs) | Repo 1 | Working pipeline even if basic |
| Helm chart quality | Strong (2 complete charts with HPA, Ingress, SA, test hook) | Strong (similar quality) | Tie | Both scaffold from `helm create` and flesh out correctly |
| Deployment strategies | None | Excellent (all 4 strategies) | Repo 2 | No contest — Repo 1 doesn't address this at all |

---

## Phase 3 — Deduplication and Selection Logic

### 1. NGINX Examples

**Repo 1:** Has resource requests/limits, volume mounts (PVC), toleration — more complete.
**Repo 2:** Minimal, no resources, no volumes — pedagogically cleaner for introduction.
**Decision: MERGE.** Layered approach: Repo 2's minimal version as introduction, Repo 1's version with resources/volumes as production-baseline.
**Improvement:** Add `readinessProbe` and `livenessProbe` — absent in both. Add `imagePullPolicy: IfNotPresent`.

### 2. MySQL Examples

**Repo 1:** StatefulSet with `volumeClaimTemplates`, headless service, 3 replicas, ConfigMap + Secret — architecturally correct.
**Repo 2:** Plain Deployment with PVC — architecturally incorrect for a stateful database.
**Decision: KEEP Repo 1, fix bugs.** Fix memory limit (25Mi → 256Mi), fix VPA kind capitalization.
**Improvement:** Add ClusterIP service alongside headless service — applications need a stable load-balanced endpoint in addition to the stable DNS names the headless service provides.

### 3. Apache RBAC

**Repo 1:** `apiGroups` includes `rbac.authorization.k8s.io` and `batch` — unnecessary. Gives access to `hpa` but `autoscaling` apiGroup not listed — rule is non-functional.
**Repo 2:** `apiGroups: ["", "apps", "extensions"]` — more accurate. Verbs include `watch`, `patch` — more operationally useful.
**Decision: KEEP Repo 2, expand.** Add ClusterRole example — cluster-wide resources require ClusterRole, concept missing from both repos.

### 4. Helm Charts

**Repo 1:** Commits `.tgz` binaries alongside source. Has typo in node-js-app chart.
**Repo 2:** Does not commit `.tgz` binaries. Cleaner values.yaml.
**Decision: MERGE, use Repo 2 structure.** Remove all `.tgz` binaries. Add `.helmignore` entries. Add `values.schema.json` stub.

### 5. Ingress

**Repo 1:** Path-based routing for two apps — demonstrates multi-backend routing.
**Repo 2:** Host-based routing (`tws.com`) with path routing — demonstrates virtual hosting.
**Decision: KEEP BOTH as separate examples.**
**Improvement:** Add TLS termination example. Add `ingressClassName: nginx` — required in Kubernetes 1.18+.

### 6. HPA + VPA

**Both repos:** HPA for Apache with `autoscaling/v2`, CPU threshold, VPA in Auto mode.
**Decision: KEEP Repo 1 version** (StatefulSet pairing). Keep Repo 2 README for documentation.
**Improvement:** Add memory metric alongside CPU. Add `stabilizationWindowSeconds` to prevent flapping.

### 7. Cluster Setup Scripts

**Repo 1:** None. **Repo 2:** Complete.
**Decision: KEEP Repo 2 entirely.** Parameterize hardcoded versions into variables at the top of each script.

### 8. Deployment Strategies

**Repo 1:** None. **Repo 2:** All four.
**Decision: KEEP Repo 2 entirely.**

### 9. Dashboard Admin User

**Both repos:** Identical `dashboard-admin-user.yml`.
**Decision: KEEP once** in `platform/observability/dashboard/`. Add strong comment: dev-only, `cluster-admin` on dashboard SA is a security anti-pattern in shared clusters.

### 10. Helm Install Script

**Both repos:** Identical `get_helm.sh`.
**Decision: KEEP once** in `setup/scripts/`.

---

## Phase 4 — Unified Architecture Design

### Complete Directory Structure

```
kube-platform/
├── README.md                          # Learning path + quickstart
├── CONTRIBUTING.md                    # Contribution guide
├── Makefile                           # Developer automation
├── .github/
│   └── workflows/
│       ├── validate-yaml.yml          # yamllint + kubeval on all YAML files
│       └── helm-lint.yml              # helm lint on all charts
│
├── setup/                             # Cluster provisioning (from Repo 2)
│   ├── README.md
│   ├── local/
│   │   ├── kind/
│   │   │   ├── README.md
│   │   │   ├── install.sh             # Parameterized (K8S_VERSION, KIND_VERSION vars)
│   │   │   └── kind-config.yml        # 1 control-plane + 2 workers
│   │   └── minikube/
│   │       ├── README.md
│   │       ├── install-linux.md
│   │       └── install-windows.md
│   ├── cloud/
│   │   └── eks/
│   │       └── README.md
│   └── kubeadm/
│       ├── README.md
│       ├── 00-common.sh               # Parameterized: K8S_VERSION at top
│       ├── 01-master.sh
│       └── 02-worker.sh
│
├── docs/                              # Conceptual documentation
│   ├── architecture.md
│   ├── deployment-strategies.md
│   └── ci-cd-concepts.md
│
├── core/                              # Kubernetes primitives
│   ├── workloads/
│   │   ├── pod/
│   │   │   ├── basic-pod.yml
│   │   │   ├── init-container.yml     # Unique to Repo 1
│   │   │   ├── sidecar-container.yml  # Unique to Repo 1
│   │   │   └── README.md
│   │   ├── deployment/
│   │   │   ├── nginx-deployment.yml   # Merged: resources + probes
│   │   │   ├── rolling-strategy.yml
│   │   │   ├── kustomize/
│   │   │   │   ├── base/
│   │   │   │   └── overlays/          # dev, staging, prod
│   │   │   └── README.md
│   │   ├── statefulset/
│   │   │   ├── mysql-namespace.yml
│   │   │   ├── mysql-configmap.yml
│   │   │   ├── mysql-secret.yml       # Bug-fixed Repo 1 version
│   │   │   ├── mysql-statefulset.yml  # Bug-fixed: memory limit corrected
│   │   │   ├── mysql-service-headless.yml
│   │   │   ├── mysql-service-clusterip.yml  # Added: missing from Repo 1
│   │   │   └── README.md
│   │   ├── daemonset/
│   │   │   ├── daemonset.yml
│   │   │   └── README.md              # Repo 2 (use cases explained)
│   │   ├── jobs/
│   │   │   ├── job.yml
│   │   │   ├── cronjob.yml
│   │   │   └── README.md
│   │   └── deployment-strategies/
│   │       ├── README.md
│   │       ├── comparison.md
│   │       ├── recreate/
│   │       ├── rolling-update/
│   │       ├── blue-green/
│   │       └── canary/
│   │
│   ├── networking/
│   │   ├── services/
│   │   │   ├── clusterip.yml
│   │   │   ├── nodeport.yml           # New — absent in both repos
│   │   │   ├── loadbalancer.yml       # New — absent in both repos
│   │   │   └── README.md
│   │   ├── ingress/
│   │   │   ├── path-based.yml         # Repo 1
│   │   │   ├── host-based.yml         # Repo 2
│   │   │   ├── tls.yml                # New — absent in both repos
│   │   │   └── README.md
│   │   └── network-policy/
│   │       ├── deny-all-ingress.yml   # New
│   │       ├── allow-same-namespace.yml # New
│   │       ├── mysql-isolation.yml    # New
│   │       └── README.md
│   │
│   ├── storage/
│   │   ├── storageclass-local.yml     # New — absent in both repos
│   │   ├── persistent-volume.yml      # Repo 1 (Retain policy)
│   │   ├── persistent-volume-claim.yml
│   │   ├── pod-with-pvc.yml
│   │   └── README.md
│   │
│   └── configuration/
│       ├── configmap.yml
│       ├── secret.yml                 # With strong warning about base64
│       └── README.md
│
├── platform/                          # Cross-cutting platform concerns
│   ├── autoscaling/
│   │   ├── README.md
│   │   ├── hpa/
│   │   │   ├── hpa-cpu-memory.yml     # Improved: both CPU + memory metrics
│   │   │   ├── hpa-with-behavior.yml  # New: stabilizationWindowSeconds
│   │   │   └── README.md
│   │   └── vpa/
│   │       ├── vpa-auto.yml           # Repo 1 with capitalization fix
│   │       └── README.md
│   │
│   ├── scheduling/
│   │   ├── taints-tolerations/
│   │   │   ├── pod-with-toleration.yml
│   │   │   └── README.md
│   │   ├── node-affinity/
│   │   │   ├── node-affinity.yml      # New
│   │   │   └── README.md
│   │   └── resource-quotas/
│   │       ├── namespace-quota.yml    # New
│   │       └── README.md
│   │
│   ├── security/
│   │   ├── rbac/
│   │   │   ├── namespace-role.yml     # Merged (Repo 2 verbs, improved)
│   │   │   ├── cluster-role.yml       # New — absent in both repos
│   │   │   ├── rolebinding.yml
│   │   │   ├── cluster-rolebinding.yml # New
│   │   │   ├── serviceaccount.yml
│   │   │   └── README.md
│   │   ├── pod-security/
│   │   │   ├── restricted-namespace.yml # New — PSS/PSA, absent in both
│   │   │   └── README.md
│   │   └── sealed-secrets/
│   │       ├── seal-secret.sh
│   │       ├── example-sealed-secret.yaml
│   │       └── README.md
│   │
│   ├── observability/
│   │   ├── dashboard/
│   │   │   ├── admin-user.yml         # Single copy with dev-only warning
│   │   │   └── README.md
│   │   └── prometheus-grafana/
│   │       ├── README.md
│   │       ├── install-stack.sh
│   │       ├── values-prometheus.yaml
│   │       ├── values-grafana.yaml
│   │       └── alerts/
│   │           ├── pod-crash-loop.yaml
│   │           └── high-cpu.yaml
│   │
│   └── extensibility/
│       ├── crd/
│       │   ├── example-crd.yml        # Repo 1, generalized
│       │   ├── example-cr.yml
│       │   └── README.md
│       └── admission/
│           ├── README.md
│           ├── install-kyverno.sh
│           └── policies/
│               ├── require-resource-limits.yaml
│               ├── require-non-root.yaml
│               ├── disallow-latest-tag.yaml
│               └── require-probes.yaml
│
├── helm/                              # Helm charts
│   ├── README.md
│   ├── get_helm.sh                    # Single copy
│   ├── apache/                        # Repo 2 chart (cleaner values.yaml)
│   │   ├── Chart.yaml
│   │   ├── .helmignore
│   │   ├── values.yaml
│   │   ├── values.schema.json         # New — JSON Schema validation
│   │   └── templates/
│   └── node-app/                      # Repo 1 chart (typo fixed, .tgz removed)
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│
├── gitops/                            # New — not in either repo
│   ├── README.md
│   ├── argocd/
│   │   ├── install.md
│   │   ├── app-of-apps.yml
│   │   └── app-project.yml
│   └── flux/
│       └── README.md
│
├── ci-cd/
│   ├── README.md
│   └── jenkins/
│       └── Jenkinsfile                # Repo 1
│
└── examples/
    ├── README.md
    ├── nginx-reference/
    │   ├── 01-intro/                  # Repo 2 minimal
    │   └── 02-production-baseline/    # Repo 1 with resources + probes
    ├── django-notes-app/              # Repo 1 (complete application)
    │   ├── Dockerfile
    │   ├── k8s/
    │   └── README.md
    ├── easyshop-kind/
    │   └── README.md                  # Repo 2 project guide
    └── online-shop/
        └── README.md                  # Repo 2 project guide
```

### Directory Rationale

**`setup/`** — Repo 2 primary. Kubeadm scripts are parameterized. Versions referenced via variables, not hardcoded in script body. KIND config updated to stable version.

**`docs/`** — Repo 2 primary. Architectural analogies are pedagogically superior. Serve as prerequisite reading before touching any YAML.

**`core/workloads/`** — Merged. Repo 1 provides StatefulSet, init container, sidecar, CronJob. Repo 2 provides DaemonSet documentation and deployment strategy implementations. MySQL StatefulSet from Repo 1 is authoritative, with bugs fixed. Added both headless and ClusterIP MySQL services.

**`core/networking/`** — Merged with additions. Both repos only show ClusterIP services and Ingress. NodePort and LoadBalancer service types added. Network policy directory is entirely new — both repos omit this fundamental security primitive despite covering RBAC.

**`core/storage/`** — Repo 1 primary. Repo 1's PV uses `persistentVolumeReclaimPolicy: Retain` (correct production default, prevents accidental data loss). StorageClass definition added — neither repo defines one.

**`platform/security/rbac/`** — Merged. Repo 2's verbs are correct (`watch`, `patch` included). RBAC resources centralized here, not scattered per-workload. ClusterRole example added.

**`platform/security/pod-security/`** — New. Neither repo addresses Pod Security Standards (PSS) or Pod Security Admission (PSA), which replaced PodSecurityPolicy in Kubernetes 1.25.

**`helm/`** — Merged. No `.tgz` binary artifacts. Repo 2's values.yaml is cleaner. Typo in Repo 1's node-js-app chart fixed. `values.schema.json` added.

---

## Phase 5 — Missing Pieces (Critical)

### 1. GitOps (ArgoCD / Flux)

Both repos treat `kubectl apply` as the deployment mechanism. In production, direct kubectl access is a security and auditability risk.

**Addition:**
```
gitops/argocd/
├── install.md         # helm install argocd + initial admin password
├── app-of-apps.yml    # ArgoCD Application pointing to kube-platform/helm/ as source
└── app-project.yml    # AppProject limiting deployment scope
```

The `examples/django-notes-app/k8s/` becomes the ArgoCD Application source — demonstrating GitOps as an operational model, not just a tool.

### 2. Secrets Management (SealedSecrets)

Both repos store base64-encoded secrets in git — universally condemned in production.

**Why SealedSecrets over Vault:** Vault requires a running cluster, adding operational complexity that defeats the purpose of a learning repo. SealedSecrets integrates directly with Kubernetes RBAC, uses asymmetric encryption, and requires zero external dependencies.

**Addition:**
```
platform/security/sealed-secrets/
├── README.md
├── seal-secret.sh     # kubectl create secret ... --dry-run=client -o yaml | kubeseal
└── example-sealed-secret.yaml
```

### 3. Observability Stack (Prometheus + Grafana)

Repo 1 mentions `helm install prometheus-stack` but has no configuration, dashboards, or alerting rules. Repo 2 has nothing.

**Addition:**
```
platform/observability/prometheus-grafana/
├── README.md
├── install-stack.sh
├── values-prometheus.yaml   # Retention, storage, alertmanager config
├── values-grafana.yaml      # Admin credentials, datasource, default dashboards
└── alerts/
    ├── pod-crash-loop.yaml  # PrometheusRule for CrashLoopBackOff
    └── high-cpu.yaml        # PrometheusRule for CPU throttling
```

### 4. Policy Enforcement (Kyverno)

Neither repo has admission control.

**Why Kyverno over OPA/Gatekeeper:** Kyverno uses Kubernetes-native YAML for policy definitions (no Rego language). Immediately readable to anyone who understands Kubernetes YAML. The `require-resource-limits` policy directly addresses the systemic issue in both repos — many example manifests lack resource constraints.

**Policies added:**
- `require-resource-limits.yaml` — Reject pods without CPU/memory limits
- `require-non-root.yaml` — Reject pods running as root
- `disallow-latest-tag.yaml` — Reject images tagged `:latest`
- `require-probes.yaml` — Reject deployments without liveness probes

### 5. Multi-Environment Configuration (Kustomize)

Both repos have no environment separation. Every YAML targets a single implicit environment.

**Structure:**
```
core/workloads/deployment/kustomize/
├── base/
│   ├── kustomization.yaml
│   └── nginx-deployment.yaml
└── overlays/
    ├── dev/     # 1 replica, nginx:latest
    ├── staging/ # 2 replicas, nginx:1.25
    └── prod/    # 4 replicas, resource limits, nginx:1.25
```

**Why Kustomize over Helm for this purpose:** Kustomize is built into `kubectl`. No additional tooling. Teaches environment differentiation as a structural concept.

### 6. Network Policies

Both repos teach RBAC (API-level access control) but omit NetworkPolicy (network-level access control). The MySQL StatefulSet from Repo 1 is accessible to every pod in the cluster by default.

**Additions:**
- `deny-all-ingress.yaml` — Default deny all incoming traffic to namespace
- `allow-same-namespace.yaml` — Allow pods within same namespace to communicate
- `allow-specific-port.yaml` — Allow traffic only to specific port from labeled pods
- `mysql-isolation.yaml` — Allow only the app namespace to reach mysql namespace

---

## Phase 6 — Final Output

### Makefile

```makefile
.DEFAULT_GOAL := help

K8S_VERSION   ?= 1.32.0
CLUSTER_NAME  ?= kube-platform

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-30s %s\n", $$1, $$2}'

cluster-up: ## Create local KIND cluster
	kind create cluster --name=$(CLUSTER_NAME) --config=setup/local/kind/kind-config.yml

cluster-down: ## Delete local KIND cluster
	kind delete cluster --name=$(CLUSTER_NAME)

lint: ## Run yamllint on all YAML files
	find . -name '*.yml' -o -name '*.yaml' | grep -v vendor | xargs yamllint -d relaxed

validate: ## Run kubeval on all YAML files
	find . -name '*.yml' -o -name '*.yaml' | grep -v vendor | \
		xargs kubeval --kubernetes-version $(K8S_VERSION) --strict

helm-lint: ## Run helm lint on all charts
	helm lint helm/apache/
	helm lint helm/node-app/

check: lint validate helm-lint ## Run all checks

install-prometheus: ## Install kube-prometheus-stack via Helm
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
		--namespace monitoring --create-namespace \
		-f platform/observability/prometheus-grafana/values-prometheus.yaml

install-argocd: ## Install ArgoCD
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd --create-namespace

install-kyverno: ## Install Kyverno policy engine
	helm repo add kyverno https://kyverno.github.io/kyverno/
	helm repo update
	helm upgrade --install kyverno kyverno/kyverno \
		--namespace kyverno --create-namespace
	kubectl apply -f platform/security/admission/policies/

bootstrap: cluster-up install-prometheus install-kyverno ## Full local dev environment
	@echo "Cluster ready. Run 'make cluster-info' to verify."

teardown: cluster-down ## Destroy local environment

port-forward-grafana: ## Forward Grafana to localhost:3000
	kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring

port-forward-argocd: ## Forward ArgoCD UI to localhost:8080
	kubectl port-forward svc/argocd-server 8080:443 -n argocd
```

### Improvements Over Original Repos

| Improvement | Problem in Original | Resolution |
|---|---|---|
| Bug-free YAML | Repo 1 has 3 reject-worthy manifests | yamllint + kubeval CI gate |
| StatefulSet-correct MySQL | Repo 2 uses Deployment for MySQL | Authoritative StatefulSet (bug-fixed) as sole MySQL definition |
| No binary artifacts in git | Repo 1 commits .tgz Helm archives | .helmignore excludes compiled artifacts |
| Single source of truth for setup | Two repos with zero overlap on cluster provisioning | Complete setup coverage under one tree |
| Environment separation | Neither repo has dev/staging/prod separation | Kustomize overlays for core workload examples |
| Secret hygiene | Both commit base64 in git | SealedSecrets track + strong warnings |
| Network security | Both omit NetworkPolicy | NetworkPolicy examples with MySQL isolation |
| Pod security | Neither addresses PSS/PSA | Namespace-level PodSecurity admission labels |
| Policy enforcement | Neither has admission control | Kyverno policies enforce resource limits, non-root, no :latest |
| Observability | Referenced but unimplemented | Prometheus/Grafana with PrometheusRules |
| GitOps | Both use imperative kubectl | ArgoCD App-of-Apps for declarative reconciliation |
| Version consistency | Three different K8s versions across Repo 2 scripts | Single version variable at script top |
| Deduplication | Duplicate helm scripts, overlapping RBAC examples | All duplicates removed |
| Complete service type coverage | Both repos only show ClusterIP | ClusterIP, NodePort, LoadBalancer all present |

---

## Bonus — OSS Standard Starter Kit

### Three signals that separate a widely-adopted starter kit from a tutorial repo:

**1. A learning path that scales with the reader:**
- Beginner: `docs/architecture.md` → `setup/local/kind/` → `core/workloads/pod/` → `core/workloads/deployment/`
- Intermediate: All of `core/` → `platform/autoscaling/` → `platform/security/rbac/` → `helm/`
- Advanced: `platform/security/` (full) → `gitops/` → Kustomize overlays → Prometheus alerting rules

**2. CI validation that is public.** The GitHub Actions badge on the README showing "All YAML valid" means every file has been verified against the Kubernetes API schema.

**3. Interview-ready patterns explicitly called out:**
- "How does Kubernetes handle rolling deployments?" → `core/workloads/deployment-strategies/rolling-update/`
- "How do you secure a namespace?" → `platform/security/rbac/` + `platform/security/pod-security/`
- "What is the difference between HPA and VPA?" → `platform/autoscaling/README.md`
- "How do you handle secrets safely?" → `platform/security/sealed-secrets/`

### What makes this portfolio-level:

- **Structured thinking:** directory hierarchy reflects how a platform team organizes cluster concerns
- **Production awareness:** sealed secrets track, network policies, Kyverno policies signal the author knows what "works in demo" differs from "safe in production"
- **CI discipline:** YAML validation in CI signals engineering rigor
- **GitOps readiness:** ArgoCD configuration signals awareness of current operational standard
- **Breadth without superficiality:** every directory has a README explaining "when" and "why not" alongside "how"

---

*This report was generated by analyzing every file in both repositories and applying production-grade platform engineering judgment to each design decision.*
