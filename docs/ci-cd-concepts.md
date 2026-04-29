# CI/CD with Kubernetes

A practical guide to Continuous Integration, Continuous Delivery, and Continuous
Deployment in the context of Kubernetes. This document covers the definitions,
how Kubernetes fits into each stage, the GitOps paradigm, and a concrete pipeline
flow you can adapt for your team.

---

## Table of Contents

1. [Definitions: CI vs CD vs Continuous Deployment](#definitions)
2. [How Kubernetes Fits Into the Pipeline](#how-kubernetes-fits-into-the-pipeline)
3. [Push-Based vs GitOps (Pull-Based) Deployment](#push-based-vs-gitops-pull-based-deployment)
4. [A Typical Pipeline Flow](#a-typical-pipeline-flow)
5. [Tooling Landscape](#tooling-landscape)
6. [Related Files in This Repository](#related-files-in-this-repository)
7. [Further Reading](#further-reading)

---

## Definitions

### Continuous Integration (CI)

**The practice of merging developer code changes into a shared repository frequently
(multiple times per day), with each merge triggering an automated build and test suite.**

CI is about eliminating "integration hell" — the pain that accumulates when long-lived
feature branches diverge from main and are merged all at once. By integrating
continuously, problems are discovered when the change set is small and the context
is fresh.

Core CI activities:
- **Source Control Trigger** — A push or pull request to a branch triggers the pipeline.
- **Build** — Compile code (or build a Docker image via `docker build`).
- **Unit Tests** — Fast, isolated tests that run in milliseconds. No external services.
- **Static Analysis / Linting** — Code style, complexity, security scanning
  (e.g., `golangci-lint`, `eslint`, `bandit` for Python).
- **Container Image Build** — Build the OCI image; tag it with the Git commit SHA.
- **Image Scanning** — Scan for known CVEs in the image layers (Trivy, Snyk, Grype).
- **Artifact Publication** — Push the vetted image to a container registry (ECR, GCR,
  Docker Hub, Harbor).

**CI is complete when a versioned, tested, scanned artifact exists in a registry.**

---

### Continuous Delivery (CD)

**The practice of ensuring that code is always in a deployable state, and that
deploying to production is a low-risk, repeatable, push-button action.**

CD extends CI by automating the deployment pipeline all the way to a production-like
environment. The key distinction from Continuous Deployment:

- **Continuous Delivery** — The pipeline runs automatically through staging/pre-prod,
  but a **human approves** the final step to production. Production deployment is
  possible at any time but is not automatic.
- The approval gate exists because of business/regulatory reasons, not technical ones.
  Any approved build should be deployable within minutes.

CD activities:
- **Deploy to staging** — Apply manifests (or run Helm/Kustomize) against a staging
  cluster. Automated.
- **Integration tests** — Test the service against its real dependencies in staging.
- **Performance/load tests** — Run Gatling, k6, or Locust to detect regressions.
- **Security/compliance scan** — DAST (Dynamic Application Security Testing).
- **Human approval gate** — A Slack message, PagerDuty alert, or CI/CD UI button.
- **Deploy to production** — Triggered by the approver.

---

### Continuous Deployment

**Every code change that passes all automated gates is deployed to production
automatically, with no human approval step.**

This is the "gold standard" for teams with mature testing, observability, and
rollback capabilities. Netflix, Google, Amazon, and Facebook all practice Continuous
Deployment for many of their services.

Requirements for safe Continuous Deployment:
- Comprehensive test coverage (unit, integration, contract, E2E).
- Automated canary analysis with data-driven promotion.
- Feature flags to decouple deployment from feature release.
- Instant rollback capability (Blue-Green or canary abort).
- Robust monitoring and alerting (SLO-based error budgets).
- Post-deployment smoke tests that run within seconds.

The difference between Continuous Delivery and Continuous Deployment is **one
approval gate**. Removing it requires building confidence in your automation.

---

### Summary Table

| Concept | Automation Level | Human Gate | Goal |
|---|---|---|---|
| Continuous Integration | Build + Test + Publish | None | Catch bugs at merge time |
| Continuous Delivery | CI + Deploy to staging + E2E tests | Approval before prod | Always have a deployable artifact |
| Continuous Deployment | CI + all the way to prod | None | Release continuously, safely |

---

## How Kubernetes Fits Into the Pipeline

Kubernetes is the **deployment target**, not the CI system. It plays several distinct
roles across the pipeline:

### 1. CI Build Environment (optional but common)

Modern CI systems (GitHub Actions, GitLab CI, Tekton, Argo Workflows) run CI jobs
**inside Kubernetes Pods**. Benefits:
- Ephemeral build environments — each job gets a fresh Pod.
- Horizontal scaling — Kubernetes schedules more Pods as the queue grows.
- Resource governance — Jobs cannot starve each other via resource quotas.
- Secrets management — K8s Secrets or external vaults inject credentials.

```yaml
# Example GitHub Actions self-hosted runner on Kubernetes
# Or Tekton PipelineRun that builds images inside a Pod
```

### 2. Staging / Pre-Production Cluster

The staging Kubernetes cluster receives every merged change automatically. Your CI
pipeline runs `kubectl apply -k overlays/staging` (or `helm upgrade`) after
publishing the new image. Integration tests run against this cluster.

### 3. Production Deployment Target

The final stage deploys to the production cluster using one of the strategies covered
in `deployment-strategies.md`:
- Rolling Update (most common, via `kubectl apply` or Helm)
- Canary (via Argo Rollouts or Flagger)
- Blue-Green (via Argo Rollouts or manual selector patch)

### 4. Kubernetes Primitives Used by CD Systems

| Kubernetes Feature | CD Usage |
|---|---|
| Namespaces | Isolate dev/staging/prod within one cluster |
| RBAC | CI service accounts have `deploy` permission only to their namespace |
| Readiness Probes | CD system waits for `rollout status` before marking success |
| PodDisruptionBudget | Prevents CD from taking down too many replicas at once |
| Horizontal Pod Autoscaler | Production scales automatically after deployment |
| Secrets | Registry credentials, database passwords injected into Pods |
| ConfigMaps | Environment-specific configuration without re-building images |

### 5. Health and Rollback

```bash
# CD system checks rollout health:
kubectl rollout status deployment/myapp --timeout=5m

# If rollout fails, CD triggers rollback:
kubectl rollout undo deployment/myapp
```

---

## Push-Based vs GitOps (Pull-Based) Deployment

This is the most important architectural decision in your CD pipeline. The two
models have fundamentally different trust and security properties.

### Push-Based Deployment

```
Developer → Git commit → CI pipeline runs → CI pipeline pushes to Kubernetes
                                              (kubectl apply / helm upgrade)
```

**How it works:**
The CI/CD system (Jenkins, GitHub Actions, GitLab CI) has credentials to the
Kubernetes cluster. After tests pass, the pipeline directly calls `kubectl apply`
or `helm upgrade` to update the cluster.

**Trust model:** The CI/CD system is trusted with cluster credentials. The cluster
is pushed to; it does not pull.

**Pros:**
- Simple to understand and implement.
- Works with any CI system.
- Immediate feedback — the CI job reports success/failure synchronously.
- Familiar to teams coming from VM-based deployments.

**Cons:**
- CI/CD system holds powerful cluster credentials — a security risk. If the CI
  system is compromised, the attacker has cluster access.
- Credentials must be rotated and distributed to every CI worker.
- Drift is possible — someone can `kubectl apply` directly to production and the
  Git repo won't reflect that.
- The cluster state is only as fresh as the last CI run. No automatic re-sync.
- Multi-cluster deployments require credentials for each cluster in the CI system.

---

### GitOps (Pull-Based) Deployment

```
Developer → Git commit (to config repo) → GitOps operator in cluster detects diff
                                          → operator applies changes from inside cluster
```

**How it works:**
A GitOps operator (Argo CD, Flux) runs **inside** the cluster and continuously
watches a Git repository (the "desired state"). When the operator detects a diff
between the Git state and the cluster state, it pulls and applies the changes.
The cluster reaches out to Git; nothing pushes into the cluster.

**Key principle:** **Git is the single source of truth.** Every cluster state change
must go through Git. `kubectl apply` directly to production is prohibited.

**Trust model:** The cluster needs read access to Git, not the other way around.
Cluster credentials never leave the cluster. Audit trail is 100% in Git history.

**Pros:**
- **Security** — No cluster credentials in the CI system. The operator has minimal
  RBAC to apply only what it manages.
- **Drift detection** — The operator continuously compares desired (Git) vs. actual
  (cluster). Manual changes are detected and can be auto-corrected.
- **Self-healing** — If someone deletes a Deployment manually, the GitOps operator
  re-creates it within seconds.
- **Auditability** — Every cluster change is a Git commit with author, timestamp,
  and diff. `git log` is your audit log.
- **Multi-cluster** — Deploy to many clusters by pointing each cluster's operator
  at the same (or different) Git repo.
- **Disaster recovery** — Rebuild a cluster from scratch by pointing a new operator
  at the Git repo.

**Cons:**
- **Complexity** — Requires learning Argo CD or Flux, structuring a config repo.
- **Asynchronous** — The CI pipeline cannot directly verify if the deployment
  succeeded. You need to poll Argo CD's API or use sync hooks.
- **Secrets management** — Secrets cannot be stored in Git in plaintext.
  Requires Sealed Secrets, SOPS, or an external vault (Vault, AWS Secrets Manager).
- **Image update automation** — Automatically updating the image tag in Git when
  a new image is published requires an additional component (Argo CD Image Updater,
  Flux Image Reflector).

---

### Comparison Table

| Dimension | Push-Based | GitOps (Pull-Based) |
|---|---|---|
| Cluster credentials location | CI/CD system | Inside the cluster (operator) |
| Source of truth | CI pipeline | Git repository |
| Drift detection | None | Continuous |
| Self-healing | None | Yes (auto-sync) |
| Audit trail | CI logs | Git history |
| Secret management | Simpler | Requires Sealed Secrets / SOPS / Vault |
| Multi-cluster | Requires creds per cluster | Each cluster has its own operator |
| Feedback latency | Synchronous | Asynchronous (poll Argo CD API) |
| Team learning curve | Low | Medium |
| Industry adoption trend | Declining | Growing (CNCF standard practice) |

**Recommendation:** For new Kubernetes projects, **start with GitOps**. Argo CD has
become the de facto standard. The security and auditability benefits are not
theoretical — they address real incidents (see: CircleCI breach 2023, where CI
system credentials were compromised).

---

## A Typical Pipeline Flow

Below is a production-grade pipeline combining CI (push-based) with GitOps
(pull-based) deployment. This "CI pushes image, GitOps deploys" hybrid is the
most common pattern in mature engineering organizations.

```
┌─────────────────────────────────────────────────────────────────────┐
│  DEVELOPER WORKSTATION                                              │
│                                                                     │
│  git commit -m "feat: add user caching"                            │
│  git push origin feature/user-caching                              │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ webhook
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 1: CI — CODE VALIDATION (GitHub Actions / GitLab CI)        │
│                                                                     │
│  ├─ Lint (eslint, golangci-lint, flake8)                           │
│  ├─ Unit tests (go test, pytest, jest) — parallel matrix           │
│  ├─ Security scan (Semgrep, Bandit, gosec)                         │
│  ├─ Dependency vulnerability scan (npm audit, Snyk, Dependabot)    │
│  └─ Build Docker image: myapp:$GIT_COMMIT_SHA                      │
│                                                                     │
│  [GATE] All checks green → proceed                                 │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 2: IMAGE PUBLICATION                                        │
│                                                                     │
│  ├─ Container image vulnerability scan (Trivy, Grype)              │
│  │   └─ CRITICAL CVEs → BLOCK publish                              │
│  ├─ Sign image with Cosign (supply chain security)                 │
│  ├─ Push to registry: ecr.aws/myorg/myapp:abc1234                  │
│  └─ Push immutable tag: ecr.aws/myorg/myapp:1.7.3                  │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 3: CONFIG REPO UPDATE (CI writes to GitOps repo)            │
│                                                                     │
│  CI job updates the image tag in the GitOps config repo:           │
│  ├─ git clone git@github.com/myorg/k8s-config                      │
│  ├─ cd overlays/staging && kustomize edit set image myapp:abc1234  │
│  ├─ git commit -m "chore: bump myapp to abc1234 [staging]"         │
│  └─ git push → triggers Argo CD sync                               │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 4: STAGING DEPLOYMENT (Argo CD — GitOps pull)               │
│                                                                     │
│  Argo CD operator (running in staging cluster):                    │
│  ├─ Detects config repo change                                     │
│  ├─ Runs kustomize build → computes desired manifests              │
│  ├─ Diffs against current cluster state                            │
│  ├─ Applies changes: kubectl apply -f ...                          │
│  ├─ Waits for rollout: kubectl rollout status                      │
│  └─ Reports sync status: Healthy / Degraded                        │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 5: AUTOMATED TESTING IN STAGING                             │
│                                                                     │
│  ├─ Integration tests (real DB, real queue, real downstream APIs)  │
│  ├─ Contract tests (Pact, consumer-driven)                         │
│  ├─ Performance tests (k6 with SLO thresholds: p99 < 200ms)       │
│  ├─ Smoke tests (critical user journeys: login, checkout, etc.)    │
│  └─ Security DAST scan (OWASP ZAP, Burp Suite)                    │
│                                                                     │
│  [GATE] All tests pass → proceed                                   │
│  [GATE for Continuous Delivery] Human approval in Argo CD / Slack  │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 6: PRODUCTION DEPLOYMENT (Argo CD — GitOps pull)            │
│                                                                     │
│  CI job (or human) updates config repo:                            │
│  ├─ kustomize edit set image myapp:abc1234 (overlays/prod)         │
│  ├─ git commit + push                                              │
│                                                                     │
│  Argo CD (production cluster):                                     │
│  ├─ Detects change → applies Canary rollout (Argo Rollouts)        │
│  ├─ 5% traffic → monitor for 30 min                               │
│  ├─ Analysis: error rate < 1%, p99 < 150ms                        │
│  ├─ 20% → 50% → 100% (automated promotion)                        │
│  └─ OR abort + roll back to previous stable image tag             │
└───────────────────────────┬─────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  STAGE 7: POST-DEPLOYMENT                                          │
│                                                                     │
│  ├─ Smoke tests run against production                             │
│  ├─ Slack notification: "myapp 1.7.3 deployed to prod ✓"          │
│  ├─ PagerDuty event: deployment marker (for alert correlation)     │
│  ├─ Datadog / Grafana deployment annotation (for dashboards)       │
│  └─ Rollback trigger: alert → Argo CD manual sync to prev revision │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Tooling Landscape

### CI Systems

| Tool | Notes |
|---|---|
| **GitHub Actions** | Tight GitHub integration; large marketplace; hosted runners |
| **GitLab CI/CD** | Built-in to GitLab; strong Kubernetes integration; free self-hosted |
| **Tekton** | Kubernetes-native CI; runs pipelines as Kubernetes CRDs; CNCF project |
| **Argo Workflows** | Kubernetes-native workflow engine; used for both CI and data pipelines |
| **Jenkins** | Mature; highly customizable; heavy operational overhead |
| **CircleCI** | Hosted; fast; docker-layer caching |

### GitOps / CD Systems

| Tool | Notes |
|---|---|
| **Argo CD** | Most popular GitOps tool; rich UI; multi-cluster; ApplicationSets |
| **Flux v2** | CNCF project; lightweight; strong Helm/Kustomize support; GitRepository CRD |
| **Argo Rollouts** | Advanced deployment strategies (Canary, Blue-Green) with analysis |
| **Flagger** | Progressive delivery; integrates with Istio, Linkerd, App Mesh |
| **Spinnaker** | Enterprise-grade; multi-cloud; Blue-Green native; complex to operate |
| **Helm** | Package manager for Kubernetes; not a CD tool but used within CD pipelines |

### Secret Management in GitOps

| Tool | Approach |
|---|---|
| **Sealed Secrets** | Encrypt secrets with a cluster public key; safe to commit to Git |
| **SOPS** | Mozilla tool; encrypts YAML/JSON with AWS KMS, GCP KMS, Age |
| **External Secrets Operator** | Syncs secrets from AWS SSM, Vault, Azure Key Vault into K8s Secrets |
| **HashiCorp Vault** | Full-featured secret management; sidecar or CSI driver injection |
| **AWS Secrets Manager + ASCP** | AWS-native; CSI driver mounts secrets into pods as files |

---

## Related Files in This Repository

This document is part of a broader reference collection:

```
/
├── docs/
│   ├── architecture.md          ← Kubernetes control plane deep dive
│   ├── deployment-strategies.md ← Recreate / Rolling / Blue-Green / Canary
│   └── ci-cd-concepts.md        ← This file
│
├── core/
│   └── workloads/
│       ├── pod/
│       │   ├── README.md
│       │   ├── basic-pod.yml
│       │   ├── init-container.yml
│       │   └── sidecar-container.yml
│       └── deployment/
│           ├── README.md
│           ├── nginx-deployment.yml    ← production deployment with probes
│           ├── rolling-strategy.yml    ← rolling update fields annotated
│           └── kustomize/
│               ├── base/              ← shared base manifests
│               └── overlays/
│                   ├── dev/           ← small resources, nginx:latest
│                   ├── staging/       ← 2 replicas, nginx:1.25
│                   └── prod/          ← 4 replicas, larger limits
```

The Kustomize overlays in `core/workloads/deployment/kustomize/` directly implement
the environment promotion model described in the pipeline above: a single base
manifest is patched per environment without duplicating YAML.

---

## Further Reading

**GitOps**
- [Argo CD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- [Flux Documentation](https://fluxcd.io/flux/)
- [OpenGitOps Principles](https://opengitops.dev/)
- [CNCF GitOps Working Group](https://github.com/cncf/tag-app-delivery/tree/main/gitops-wg)
- [GitOps Tech — What is GitOps?](https://www.gitops.tech/)

**CI/CD Patterns**
- [Google — Testing on the Toilet: Change Detector Tests Considered Harmful](https://testing.googleblog.com/2015/01/testing-on-toilet-change-detector-tests.html)
- [Martin Fowler — Continuous Delivery](https://martinfowler.com/books/continuousDelivery.html)
- [The Twelve-Factor App — Build, Release, Run](https://12factor.net/build-release-run)
- [DORA State of DevOps Report](https://dora.dev/research/)

**Security in the Pipeline**
- [SLSA — Supply Chain Levels for Software Artifacts](https://slsa.dev/)
- [Sigstore / Cosign — Container Image Signing](https://docs.sigstore.dev/)
- [CNCF Security Whitepaper](https://github.com/cncf/tag-security/blob/main/security-whitepaper/CNCF_cloud-native-security-whitepaper-May2022-v2.pdf)
- [CircleCI Breach Post-Mortem — Why CI Credentials Are High-Value Targets](https://circleci.com/blog/jan-4-2023-incident-report/)
