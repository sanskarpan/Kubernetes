# Deployments

A Deployment is the standard way to run a stateless, replicated application in
Kubernetes. It provides declarative updates, rolling rollouts, rollback, scaling,
and self-healing for a set of identical Pods.

Understanding the Deployment → ReplicaSet → Pod ownership chain is fundamental to
debugging and operating production workloads.

---

## Table of Contents

1. [What a Deployment Manages](#what-a-deployment-manages)
2. [The ReplicaSet Chain](#the-replicaset-chain)
3. [Rolling Update Mechanics](#rolling-update-mechanics)
4. [Key Fields Explained](#key-fields-explained)
5. [Common Operations](#common-operations)
   - [Rollback Commands](#rollback-commands)
   - [Scaling Commands](#scaling-commands)
   - [Pause and Resume](#pause-and-resume-for-canary-testing)
6. [Deployment vs. StatefulSet vs. DaemonSet](#deployment-vs-statefulset-vs-daemonset)
7. [Interview Prep](#interview-prep)
8. [Files in This Directory](#files-in-this-directory)

---

## What a Deployment Manages

A Deployment declares the **desired state** of a set of Pods:
- How many replicas should run (`spec.replicas`)
- What container image to use (`spec.template.spec.containers[].image`)
- How to update them (`spec.strategy`)
- When an update is considered successful (`spec.minReadySeconds`, readiness probes)

The Deployment does not manage Pods directly. It creates and manages **ReplicaSets**,
which in turn create and manage **Pods**.

```
Deployment
  └── ReplicaSet (v1 — current)
        ├── Pod
        ├── Pod
        └── Pod
  └── ReplicaSet (v2 — previous, scaled to 0, kept for rollback)
  └── ReplicaSet (v3 — older, kept for rollback)
```

---

## The ReplicaSet Chain

When you update a Deployment's Pod template (e.g., change the image tag), Kubernetes
does NOT modify the existing ReplicaSet. It:

1. Creates a **new ReplicaSet** with the new template hash in its name.
2. Scales the new ReplicaSet up (adds Pods).
3. Scales the old ReplicaSet down (removes Pods).
4. The old ReplicaSet is kept at 0 replicas (for rollback), up to
   `spec.revisionHistoryLimit` (default 10, we set 5).

```
Before update:
  deploy/nginx   replicas=3
  └── rs/nginx-7d4f8bc   replicas=3  ← v1 ReplicaSet

After update (in progress):
  deploy/nginx   replicas=3
  ├── rs/nginx-7d4f8bc   replicas=2  ← v1 scaling down
  └── rs/nginx-9b1c3de   replicas=2  ← v2 scaling up (maxSurge=1)

After update (complete):
  deploy/nginx   replicas=3
  ├── rs/nginx-7d4f8bc   replicas=0  ← v1 kept for rollback
  └── rs/nginx-9b1c3de   replicas=3  ← v2 now live
```

This is why `kubectl rollout undo` is fast — it simply scales the previous
ReplicaSet back up and scales the current one down.

---

## Rolling Update Mechanics

With these settings:
```yaml
replicas: 4
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
minReadySeconds: 10
```

The update proceeds as follows:

```
Step 1: Create 1 new Pod (total: 5 = 4 + 1 surge)
        Wait for new Pod to pass readinessProbe AND be Ready for 10s (minReadySeconds)

Step 2: Terminate 1 old Pod (total: 4, with 1 new + 3 old)
        0 unavailable (maxUnavailable=0 ensures no capacity is lost)

Step 3: Create 1 new Pod (total: 5), wait for Ready + minReadySeconds

Step 4: Terminate 1 old Pod (total: 4, with 2 new + 2 old)

...repeat until all old Pods are replaced...

Final: 4 new Pods running. Old ReplicaSet at 0. Rollout complete.
```

**What halts a rollout?**
- A new Pod fails its `readinessProbe` — it never becomes "Ready", so the
  Deployment controller never considers it available, and the rollout stalls.
- The rollout stalls until `progressDeadlineSeconds` (default 600s) expires,
  at which point the Deployment is marked `ProgressDeadlineExceeded`.
- `kubectl rollout undo` can be run at any point to revert.

---

## Key Fields Explained

```yaml
spec:
  replicas: 3
  # Keep the last 5 ReplicaSets for rollback. Default is 10.
  # Lower values reduce etcd storage but limit how far back you can roll back.
  revisionHistoryLimit: 5

  # A new Pod must be Ready for this many seconds before it counts as "available".
  # Prevents a Pod that immediately crashes after becoming Ready from being
  # treated as a successful update step. Set to your app's warm-up time.
  minReadySeconds: 10

  # If the rollout does not make progress within this window, the Deployment
  # is marked as Failed (DeploymentCondition: ProgressDeadlineExceeded).
  # This surfaces in monitoring and can be used as an alert condition.
  progressDeadlineSeconds: 600

  selector:
    # The selector is IMMUTABLE after creation. Changing it requires deleting
    # and recreating the Deployment. The selector must match the Pod template labels.
    matchLabels:
      app.kubernetes.io/name: nginx

  strategy:
    type: RollingUpdate
    rollingUpdate:
      # Number of Pods above the desired replica count during update.
      # Can be absolute (1) or percentage ("25%").
      # Larger values = faster rollout but more resource usage during update.
      maxSurge: 1

      # Number of Pods that can be unavailable during the update.
      # 0 = zero-downtime (never drop below desired replica count).
      # Can be absolute or percentage.
      maxUnavailable: 0

  template:
    metadata:
      labels:
        # Pod template labels MUST match spec.selector.matchLabels
        app.kubernetes.io/name: nginx
    spec:
      # ... pod spec ...
```

---

## Common Operations

### Rollback Commands

```bash
# Check the status of an in-progress rollout
kubectl rollout status deployment/nginx -n workloads
# Output: Waiting for deployment "nginx" rollout to finish: 1 out of 3 new replicas have been updated...

# View the rollout history (shows revisions)
kubectl rollout history deployment/nginx -n workloads

# View the details of a specific revision (what changed)
kubectl rollout history deployment/nginx -n workloads --revision=3

# Rollback to the PREVIOUS revision (most common rollback)
kubectl rollout undo deployment/nginx -n workloads

# Rollback to a SPECIFIC revision number
kubectl rollout undo deployment/nginx -n workloads --to-revision=2

# Verify the rollback is complete
kubectl rollout status deployment/nginx -n workloads
```

### Scaling Commands

```bash
# Scale a deployment manually (replaces spec.replicas in the live object)
kubectl scale deployment/nginx --replicas=6 -n workloads

# Scale to zero (stops all traffic; useful for emergency stop)
kubectl scale deployment/nginx --replicas=0 -n workloads

# Conditional scale: only scale if current replicas == 3
kubectl scale deployment/nginx --replicas=6 --current-replicas=3 -n workloads

# Enable HorizontalPodAutoscaler (automates scaling based on CPU)
kubectl autoscale deployment/nginx --min=2 --max=10 --cpu-percent=70 -n workloads

# Check HPA status
kubectl get hpa nginx -n workloads
```

### Pause and Resume for Canary Testing

Pause/resume is a lightweight "manual canary" technique using native Deployment
features. It lets you ship a partial rollout and test it before proceeding.

```bash
# Pause the rollout (prevent the controller from continuing the update)
kubectl rollout pause deployment/nginx -n workloads

# Now update the image (or other fields) — the Deployment is paused,
# so the controller will NOT apply these changes yet.
kubectl set image deployment/nginx nginx=nginx:1.26 -n workloads

# Check the current state (some Pods on v1.25, some on v1.26 — the paused state)
kubectl get pods -n workloads -o wide

# Run smoke tests against the cluster. Use a Service to test both versions,
# or exec into a v1.26 Pod directly.
kubectl exec -it <pod-name> -n workloads -- curl localhost/health

# If tests pass: resume the rollout (continues updating remaining Pods)
kubectl rollout resume deployment/nginx -n workloads

# If tests fail: undo the paused update (reverts all changes including the pause)
kubectl rollout undo deployment/nginx -n workloads

# Verify final state
kubectl rollout status deployment/nginx -n workloads
```

**Note:** Pause/resume is simpler than Argo Rollouts but coarser — you can't control
the exact traffic percentage to the new version. For production-grade canary with
traffic weighting, use Argo Rollouts with a service mesh.

---

## Deployment vs. StatefulSet vs. DaemonSet

| | Deployment | StatefulSet | DaemonSet |
|---|---|---|---|
| **Use for** | Stateless apps (web servers, APIs, workers) | Stateful apps (databases, queues, search engines) | Node-level agents (monitoring, logging, CNI) |
| **Pod names** | Random hash suffix (pod-abc12) | Stable ordinal (pod-0, pod-1, pod-2) | One per node, node name in pod name |
| **Scaling order** | Simultaneous | Ordered (0 → 1 → 2) | N/A (one per node) |
| **Deletion order** | Simultaneous | Reverse order (2 → 1 → 0) | N/A |
| **Stable network identity** | No (Pod IP changes on restart) | Yes (headless Service gives stable DNS) | No |
| **Stable storage** | No (use external storage) | Yes (VolumeClaimTemplates give per-pod PVC) | Per-node storage |
| **Rolling update default** | Yes | Yes (ordered) | Yes (one at a time) |
| **Example workloads** | nginx, API server, Celery worker | PostgreSQL, Kafka, Elasticsearch, ZooKeeper | Fluentd, Prometheus node-exporter, Calico node, kube-proxy |

---

## Interview Prep

> **"What is the difference between a Deployment and a ReplicaSet?"**

A ReplicaSet ensures N copies of a Pod template are running. It has no concept of
versions or rollout history. A Deployment is a higher-level abstraction that manages
ReplicaSets: when you update the Pod template, it creates a new ReplicaSet and
coordinates the transition (rolling update) from the old ReplicaSet to the new one.
The Deployment also keeps old ReplicaSets (scaled to 0) for rollback. In practice,
you always use Deployments — you rarely interact with ReplicaSets directly.

> **"How does a rolling update work? Can it cause downtime?"**

With `maxUnavailable: 0` and a working `readinessProbe`, a rolling update should
not cause downtime. The Deployment controller creates new Pods first (up to `maxSurge`
above desired), waits for them to pass readiness (and `minReadySeconds`), then
terminates old Pods. At no point does the available capacity drop below the desired
replica count. However, rolling updates can cause downtime if: the readiness probe
is misconfigured (reports Ready prematurely), `maxUnavailable > 0`, or the preStop
hook is too short and requests are dropped during termination.

> **"What happens to traffic during a rolling update?"**

Traffic continues to flow to all Ready Pods throughout the update. During the update,
some Pods serve the old version and some serve the new — they both receive traffic
simultaneously. This means your old and new API versions must be backward-compatible.
When a new Pod becomes Ready, it is added to the Service's EndpointSlice and starts
receiving traffic. When an old Pod is terminated, it is removed from the
EndpointSlice (the preStop hook gives time for the load balancer to drain it).

> **"How do you roll back a Deployment in production?"**

`kubectl rollout undo deployment/<name>` is the fastest path — it scales the
previous ReplicaSet back up and the current one down, using the same rolling update
mechanics. For a specific revision: `kubectl rollout undo --to-revision=N`.
In a GitOps workflow, you would instead `git revert` the image tag change in the
config repo and push, letting Argo CD re-sync. This keeps the Git history accurate.

> **"What is `minReadySeconds` and why is it important?"**

`minReadySeconds` is the time a newly created Pod must be in the Ready state
(continuously) before the Deployment controller considers it truly Available and
proceeds to the next step. Without `minReadySeconds: 0` (the default), a Pod that
crashes 1 second after becoming Ready would still be counted as available, and the
rollout would proceed even though the Pod is about to restart. Setting it to a
reasonable value (e.g., 10–30s for most apps) prevents premature declaration of
success for flaky Pods.

---

## Files in This Directory

| File | Description |
|---|---|
| `README.md` | This file |
| `nginx-deployment.yml` | Production-grade nginx Deployment with probes, configmap, security contexts |
| `rolling-strategy.yml` | Demonstrates all rolling update fields with inline explanations |
| `kustomize/` | Kustomize base + overlays (dev/staging/prod) |
| `kustomize/base/` | Shared base manifests without environment-specific values |
| `kustomize/overlays/dev/` | Dev environment: 1 replica, nginx:latest, small limits |
| `kustomize/overlays/staging/` | Staging: 2 replicas, nginx:1.25, medium limits |
| `kustomize/overlays/prod/` | Production: 4 replicas, nginx:1.25, larger limits |
