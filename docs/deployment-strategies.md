# Kubernetes Deployment Strategies

A comprehensive comparison of the four primary deployment strategies used in
production Kubernetes environments. Each strategy makes different trade-offs between
downtime risk, resource consumption, rollback speed, and operational complexity.
Choosing the right strategy depends on your service's SLA, traffic patterns, and
team maturity.

---

## Table of Contents

1. [Strategy Overview](#strategy-overview)
2. [Recreate](#1-recreate)
3. [Rolling Update](#2-rolling-update)
4. [Blue-Green](#3-blue-green)
5. [Canary](#4-canary)
6. [Decision Matrix](#decision-matrix)
7. [When to Use Each in Production](#when-to-use-each-in-production)
8. [Industry Examples](#industry-examples)
9. [Further Reading](#further-reading)

---

## Strategy Overview

```
STRATEGY         DOWNTIME?   EXTRA RESOURCES   ROLLBACK SPEED   RISK      COMPLEXITY
─────────────────────────────────────────────────────────────────────────────────────
Recreate         Yes         None              Fast (redeploy)  High      Low
Rolling Update   No*         ~1 pod extra      Medium           Medium    Low
Blue-Green       No          2x (full copy)    Instant          Low       Medium
Canary           No          Partial (%)       Fast             Very Low  High
```

---

## 1. Recreate

### What It Is

The Recreate strategy terminates **all existing Pods first**, then starts the new
version. The cluster is intentionally empty between the two generations.

### How It Works in Kubernetes

```yaml
strategy:
  type: Recreate
```

Kubernetes's Deployment controller:
1. Scales the existing ReplicaSet to 0 (all old Pods receive SIGTERM).
2. Waits for all old Pods to be terminated.
3. Creates a new ReplicaSet with the new template and scales it to the desired count.

### Timeline

```
Time ──────────────────────────────────────────────────────────►

[v1 Pods running]
        │  kubectl apply (new version)
        ▼
[ALL v1 Pods terminated]  ← DOWNTIME WINDOW BEGINS
        │
        ▼
[ALL v2 Pods starting]    ← DOWNTIME WINDOW ENDS when v2 is Ready
        │
        ▼
[v2 Pods running] ── traffic resumes
```

### Pros

- **Simplicity** — No version co-existence; zero risk of mixed-version traffic.
- **No resource overhead** — No extra nodes or Pods needed.
- **Predictable** — Easy to reason about; useful for stateful apps where two
  versions cannot run simultaneously (e.g., database schema is not backward-compatible).
- **Clean state** — Every instance starts fresh; no lingering v1 connections.

### Cons

- **Guaranteed downtime** — The window between old termination and new readiness is
  a hard outage. For slow-starting applications this can be significant.
- **No gradual validation** — The new version is "all or nothing". If v2 crashes,
  all traffic is impacted.
- **Poor for SLA-sensitive services** — Any service with an uptime SLA > 99% cannot
  afford planned downtime per deployment.

### When to Use Recreate

- Development environments where downtime is acceptable.
- Batch processing jobs or workers with no live traffic.
- Database schema migrations where you cannot run v1 and v2 simultaneously.
- Internal tooling with low-traffic windows (deploy at 2 AM).
- Legacy monoliths being containerized for the first time.

---

## 2. Rolling Update

### What It Is

Rolling Update gradually replaces old Pods with new ones, ensuring that some
capacity is always available. It is the **default Kubernetes strategy** for good
reason: zero downtime with minimal resource overhead.

### How It Works in Kubernetes

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # How many extra Pods can exist above the desired count
    maxUnavailable: 0  # How many Pods can be unavailable during the update
```

With `replicas: 4`, `maxSurge: 1`, `maxUnavailable: 0`:
1. Create 1 extra new Pod (total: 5) — wait for it to be Ready.
2. Terminate 1 old Pod (total: 4, but 1 is new).
3. Create 1 more new Pod (total: 5), wait for Ready.
4. Terminate 1 more old Pod... repeat until all 4 are new.

### Timeline

```
Time ──────────────────────────────────────────────────────────►

Pods:  [v1][v1][v1][v1]
                     │ kubectl apply
                     ▼
       [v1][v1][v1][v1][v2]  ← surge: +1 new (wait for Ready)
       [v1][v1][v1]   [v2]   ← remove 1 old
       [v1][v1][v1][v2][v2]  ← surge: +1 new (wait for Ready)
       [v1][v1]   [v2][v2]   ← remove 1 old
       ... (continues until all v1 replaced)
       [v2][v2][v2][v2]      ← rollout complete
```

### Key Fields

| Field | Effect |
|---|---|
| `maxSurge: 1` | At most 1 extra Pod above `replicas` at any time |
| `maxSurge: 25%` | Can be a percentage of `replicas` |
| `maxUnavailable: 0` | Never go below desired replica count (zero-downtime) |
| `maxUnavailable: 1` | Allow 1 Pod to be unavailable (faster rollout) |
| `minReadySeconds: 10` | A new Pod must be Ready for 10s before being considered available |
| `progressDeadlineSeconds: 600` | Rollout is marked Failed if not complete in 10 min |

### Pros

- **Zero downtime** (with `maxUnavailable: 0`).
- **Minimal resource overhead** — only `maxSurge` extra Pods at any time.
- **Built-in health gating** — `readinessProbe` failures halt the rollout.
- **Easy rollback** — `kubectl rollout undo deployment/<name>`.
- **Simple** — Native Kubernetes; no extra tooling required.

### Cons

- **Two versions run simultaneously** — Requests may be served by v1 or v2 during
  the rollout. APIs must be backward-compatible.
- **Slow for large fleets** — With `maxSurge: 1` and 100 replicas, you cycle through
  100 iterations. Increase `maxSurge` (e.g., 25%) to speed up.
- **No traffic weighting** — You can't send 5% of traffic to the new version;
  it's proportional to the number of ready Pods.
- **Stateful apps** — Rolling updates of StatefulSets are ordered and slower.

### Rollback

```bash
# Check rollout status
kubectl rollout status deployment/nginx

# View rollout history
kubectl rollout history deployment/nginx

# Rollback to previous revision
kubectl rollout undo deployment/nginx

# Rollback to a specific revision
kubectl rollout undo deployment/nginx --to-revision=3
```

---

## 3. Blue-Green

### What It Is

Blue-Green maintains **two identical production environments** (Blue = current,
Green = new). Traffic is switched atomically from Blue to Green using a Service
selector update. Rollback is instant — just flip the selector back.

### How It Works in Kubernetes

Kubernetes does not have a native Blue-Green resource. It is implemented using:
- Two Deployments: one labeled `slot: blue`, one labeled `slot: green`.
- One Service whose `selector` points to either `slot: blue` or `slot: green`.

```yaml
# Blue Deployment (currently live)
metadata:
  name: myapp-blue
spec:
  template:
    metadata:
      labels:
        app: myapp
        slot: blue  # Service selector targets this

# Green Deployment (new version, being validated)
metadata:
  name: myapp-green
spec:
  template:
    metadata:
      labels:
        app: myapp
        slot: green  # Service selector does NOT target this yet
```

Traffic switch (zero-downtime):
```bash
kubectl patch service myapp -p '{"spec":{"selector":{"slot":"green"}}}'
```

Rollback (instant):
```bash
kubectl patch service myapp -p '{"spec":{"selector":{"slot":"blue"}}}'
```

### Timeline

```
Time ──────────────────────────────────────────────────────────►

[BLUE: v1 running — 100% traffic]

         Deploy GREEN (v2), run smoke tests — NO traffic yet
         GREEN validated ✓

         kubectl patch service → selector: green
         ↓
[BLUE: v1 idle]     [GREEN: v2 — 100% traffic]

         Issue detected → kubectl patch service → selector: blue (INSTANT)

[BLUE: v1 — 100% traffic]  ← full rollback in seconds
```

### Pros

- **Instant rollback** — A single `kubectl patch` reverts all traffic immediately.
- **Full pre-production validation** — Green can be smoke-tested with real
  infrastructure (databases, service mesh) before receiving traffic.
- **No mixed versions** — Traffic is served by exactly one version at all times.
- **Clean swap** — No gradual exposure means no need for v1/v2 API compatibility
  (assuming the switch is fast relative to in-flight requests).

### Cons

- **2x resource cost** — You maintain a full second copy of every Pod. This doubles
  your compute bill during deployments.
- **Database migrations** — If v2 requires a DB schema change, you must migrate the
  schema before the switch (making it additive/backward-compatible) or accept a
  brief compatibility window.
- **State / sticky sessions** — In-flight sessions on Blue may be dropped when
  traffic switches to Green. Use session draining or sticky sessions carefully.
- **Operational overhead** — Requires automation to manage two environments;
  easy to forget to scale down the idle slot (wasting money).
- **Not built-in** — Requires discipline in label/selector naming conventions.

### Implementation Notes

Tools that automate Blue-Green in Kubernetes:
- **Argo Rollouts** — `strategy: blueGreen` with automatic analysis and promotion.
- **Flux Flagger** — Progressive delivery controller with Blue-Green support.
- **Spinnaker** — Pipeline-based delivery platform with Blue-Green stages.

---

## 4. Canary

### What It Is

Canary releases gradually shift a **small percentage of traffic** to the new version,
monitor it for errors and latency regressions, and progressively increase the
percentage until the new version handles 100% of traffic (or the release is aborted).

The name comes from the "canary in a coal mine" — a small, controlled exposure that
detects danger before it affects everyone.

### How It Works in Kubernetes

**Native Kubernetes (approximate traffic splitting via replica ratio):**

```
10 replicas v1, 1 replica v2 → ~9% canary traffic
↓ promote (metrics look good)
9 replicas v1, 2 replicas v2  → ~18% canary traffic
...continue until v2 = 10
```

This is coarse-grained (limited by replica count) and requires API compatibility
between versions. For precise traffic splitting (e.g., exactly 5%), you need:

**Precise traffic splitting options:**
- **Argo Rollouts + Istio/Gateway API** — Weight-based traffic split at the service
  mesh level (completely independent of replica count).
- **Nginx Ingress** — `nginx.ingress.kubernetes.io/canary-weight: "10"` annotation.
- **Flagger** — Automated canary analysis with Prometheus metrics gates.

### Timeline

```
Time ──────────────────────────────────────────────────────────────────►

v1: [●][●][●][●][●][●][●][●][●][●]   100%
                    ↓ deploy canary
v1: [●][●][●][●][●][●][●][●][●]  90%
v2: [●]                            10%  ← monitor error rate, p99 latency

(metrics OK after 30 min)
v1: [●][●][●][●][●][●][●][●]      80%
v2: [●][●]                         20%

(metrics OK after 1 hour)
v1: [●][●][●][●][●]               50%
v2: [●][●][●][●][●]               50%

(metrics OK)
v1: []                              0%
v2: [●][●][●][●][●][●][●][●][●][●] 100% ← full promotion

OR:
(ERROR RATE SPIKE at any stage → abort, route all traffic back to v1)
```

### Key Metrics to Monitor During Canary

| Signal | Typical Threshold |
|---|---|
| HTTP 5xx error rate | < 1% of requests |
| p99 latency | < 1.5x baseline |
| p50 latency | < 1.2x baseline |
| Pod restart count | 0 restarts in window |
| Custom business metrics | Conversion rate, checkout success, etc. |

### Pros

- **Lowest blast radius** — Only a small fraction of users experience a bad release.
- **Real production validation** — Canary traffic is real users, real load, real data.
  Catches issues that staging never surfaces.
- **Data-driven promotion** — Automated analysis (Argo Rollouts `AnalysisTemplate`)
  gates promotion on actual metrics.
- **Gradual confidence building** — Engineers gain confidence progressively, not
  all at once.

### Cons

- **Highest operational complexity** — Requires a service mesh or advanced Ingress,
  metrics pipeline, and automated analysis setup.
- **Two versions in production simultaneously** — All the API compatibility concerns
  of Rolling Update apply, but for a longer, intentional window.
- **Debugging is harder** — "Why do 10% of users see errors?" is a harder
  conversation than "the new version is broken".
- **Slow for low-traffic services** — Statistical significance requires enough
  requests. A service with 10 RPM may take hours to accumulate sufficient data.

---

## Decision Matrix

| | **Recreate** | **Rolling Update** | **Blue-Green** | **Canary** |
|---|:---:|:---:|:---:|:---:|
| **Downtime** | Yes | No* | No | No |
| **Resource Overhead** | None | ~1 Pod extra | 2x full copy | Partial (canary %) |
| **Rollback Speed** | Slow (redeploy) | Medium (undo) | Instant (selector patch) | Fast (abort + reroute) |
| **Traffic Control Precision** | N/A | Coarse (by replica %) | All-or-nothing | Fine-grained (%) |
| **Production Risk** | High | Medium | Low | Very Low |
| **API Compatibility Required** | No | Yes (during rollout) | No (atomic switch) | Yes (during canary) |
| **Infrastructure Complexity** | Low | Low | Medium | High |
| **Suitable for Stateful Apps** | Sometimes | With care | Better | With care |
| **Cost During Deployment** | Lowest | Low | 2x | Low–Medium |
| **Best For** | Dev / batch | Most production workloads | High-stakes releases | High-volume, risk-averse teams |

\* Zero downtime with `maxUnavailable: 0` and working `readinessProbe`.

---

## When to Use Each in Production

### Use Recreate When:
- The workload is a **batch job** or background worker with no live HTTP traffic.
- Running **database schema migrations** where v1 and v2 are incompatible.
- You are in a **development or CI environment** and downtime is acceptable.
- The application explicitly **cannot** run two versions concurrently (e.g., it holds
  an exclusive lock or distributed lease).

### Use Rolling Update When:
- You have a standard, stateless web service or API.
- Your API is **backward-compatible** between versions.
- You want **zero-downtime** with **minimal resource cost** and **no extra tooling**.
- You are deploying **frequently** (multiple times per day) and need a fast,
  simple default.
- This is the **right default** for 80%+ of Kubernetes workloads.

### Use Blue-Green When:
- You need **guaranteed instant rollback** (e.g., payment processing, order systems).
- You want to **validate the new version** against real infrastructure before it
  receives any traffic.
- You have **budget** for 2x resources during deployments.
- Your service has **long-lived connections** (WebSocket, gRPC streaming) that cannot
  be gracefully migrated mid-deployment.
- You are doing a **major version upgrade** that changes external contracts.

### Use Canary When:
- You deploy a **high-volume service** (>1000 RPM) where statistical significance
  for canary analysis is achievable quickly.
- You have a **mature observability stack** (Prometheus, Grafana, distributed tracing).
- You have a **risk-averse culture** or a history of regressions in production.
- You are running **A/B tests** or **feature flags** alongside deployment.
- You have invested in a **service mesh** (Istio, Linkerd) or **Argo Rollouts**.

---

## Industry Examples

### Google — Canary

Google has used canary releases as a core deployment primitive for over a decade,
described in the SRE Book as "canarying." Their internal deployment system
(Borg/Kubernetes) supports automatic canary analysis, rolling out changes to 1% of
traffic, then 5%, 10%, 50%, before full promotion. Every change to a high-visibility
service like Search or Gmail goes through this process. The key insight Google
operationalized: **production is the only environment that matters for validation**.
Their error budget framework (SLI/SLO/error budget) directly drives whether a canary
can proceed.

Reference: [Google SRE Book, Chapter 8 — Release Engineering](https://sre.google/sre-book/release-engineering/)

### Netflix — Blue-Green

Netflix pioneered Blue-Green deployment (along with Chaos Engineering) as a
core reliability pattern. Their Spinnaker deployment platform, which they open-sourced
in 2015, has Blue-Green as a first-class deployment stage. Netflix runs multiple
AWS regions and uses Blue-Green to deploy their streaming backend, enabling instant
rollback without affecting the 200M+ subscribers watching at any given moment.
Their philosophy: **"Always be ready to roll back instantly."** Spinnaker's automated
canary analysis (Kayenta) was a later addition that combines both strategies.

Reference: [Netflix Tech Blog — Automated Canary Analysis at Netflix](https://netflixtechblog.com/automated-canary-analysis-at-netflix-with-kayenta-3260bc7acc69)

### Amazon — Rolling Updates (with Canary for high-risk changes)

Amazon uses Rolling Updates as the default for most of their microservices on ECS
and EKS, relying on health check gating to prevent bad versions from fully rolling out.
For high-risk changes (new algorithms, infrastructure changes affecting all customers),
they use weighted routing via AWS Route 53 or Application Load Balancer to implement
canary-style deployments at the infrastructure layer. Their one-way door vs. two-way
door framework maps directly to deployment strategy selection: reversible decisions
(two-way doors) use Rolling Updates; irreversible decisions use Canary or Blue-Green.

### GitLab — Canary with Feature Flags

GitLab deploys GitLab.com (running on Kubernetes) using Canary deployments combined
with feature flags. Their "deploy to a canary stage first" model means every
deployment first reaches their internal users (GitLab employees use GitLab.com) and
a small percentage of external users before full rollout. They use LaunchDarkly-style
feature flags to decouple deployment from feature release.

Reference: [GitLab's Deployment Strategy](https://about.gitlab.com/blog/2021/02/05/ci-deployment-and-environments/)

### Uber — Canary with Automated Gates

Uber's deployment platform (Peloton/internally developed) enforces canary deployments
for all production services. Automated gates check:
- Error rate delta vs. baseline
- p99 latency delta
- Custom business metrics (trip requests, driver availability)

If any gate fails, the deployment is automatically rolled back without human
intervention. Uber's scale (millions of trips per day) means canary data accumulates
within minutes, making statistical analysis fast and reliable.

---

## Further Reading

- [Kubernetes Deployment Strategies (Argo Rollouts)](https://argoproj.github.io/argo-rollouts/concepts/)
- [Flagger Progressive Delivery](https://flagger.app/)
- [Martin Fowler — BlueGreenDeployment](https://martinfowler.com/bliki/BlueGreenDeployment.html)
- [Martin Fowler — CanaryRelease](https://martinfowler.com/bliki/CanaryRelease.html)
- [Google SRE Book — Chapter 8: Release Engineering](https://sre.google/sre-book/release-engineering/)
- [Netflix Spinnaker](https://spinnaker.io/)
- [Kayenta: Automated Canary Analysis](https://netflixtechblog.com/automated-canary-analysis-at-netflix-with-kayenta-3260bc7acc69)
- [Kubernetes Rolling Update docs](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment)
