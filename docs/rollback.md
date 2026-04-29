# Kubernetes Deployment Rollback Procedures

This guide covers how to safely roll back Kubernetes Deployments, Helm releases, and GitOps-managed applications. It also covers preventing bad rollouts and verifying a rollback was successful.

---

## Table of Contents

1. [Rollout History and Revision Tracking](#1-rollout-history-and-revision-tracking)
2. [Checking Rollout Status](#2-checking-rollout-status)
3. [Rollback to the Previous Version](#3-rollback-to-the-previous-version)
4. [Rollback to a Specific Revision](#4-rollback-to-a-specific-revision)
5. [Helm Rollback](#5-helm-rollback)
6. [GitOps Rollback](#6-gitops-rollback)
7. [PodDisruptionBudget During Rollback](#7-poddisruptionbudget-during-rollback)
8. [Preventing Bad Rollouts](#8-preventing-bad-rollouts)
9. [Post-Rollback Verification Checklist](#9-post-rollback-verification-checklist)

---

## 1. Rollout History and Revision Tracking

Kubernetes tracks Deployment rollout history through ReplicaSets. Each time you apply a change to a Deployment's pod template (`spec.template`), a new ReplicaSet is created with an incremented revision number.

### View rollout history

```bash
kubectl rollout history deployment/<deployment-name> -n <namespace>
```

Example output:
```
REVISION  CHANGE-CAUSE
1         kubectl apply --filename=deployment.yaml
2         Image updated to v1.2.0
3         Image updated to v1.3.0 (current)
```

### Add a change cause annotation

Kubernetes records the `CHANGE-CAUSE` from the `kubernetes.io/change-cause` annotation. Set it before applying:

```bash
kubectl annotate deployment/<name> \
  kubernetes.io/change-cause="Release v1.3.0 — add payment API endpoint" \
  -n <namespace>
```

Or set it in the Deployment manifest:
```yaml
metadata:
  annotations:
    kubernetes.io/change-cause: "Release v1.3.0 — add payment API endpoint"
```

### View a specific revision's details

```bash
kubectl rollout history deployment/<name> -n <namespace> --revision=2
```

This shows the pod template spec at that revision — image, environment variables, resource limits, etc.

### How many revisions are retained?

Controlled by `spec.revisionHistoryLimit` (default: 10). Old ReplicaSets are retained (with 0 replicas) to enable rollback. Setting `revisionHistoryLimit: 0` disables rollback capability — avoid this in production.

```yaml
spec:
  revisionHistoryLimit: 10   # keep last 10 revisions
```

### List ReplicaSets to see revision ownership

```bash
kubectl get replicasets -n <namespace> -l app=<app-label> \
  --sort-by='.metadata.creationTimestamp'
```

Each RS has a `deployment.kubernetes.io/revision` annotation. The RS with replicas > 0 is the current one.

---

## 2. Checking Rollout Status

Before and after a rollout or rollback, verify progress:

```bash
kubectl rollout status deployment/<name> -n <namespace>
```

This command **blocks** until the rollout is complete or fails, making it suitable for CI/CD pipelines:

```
Waiting for deployment "my-app" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "my-app" rollout to finish: 2 old replicas are pending termination...
deployment "my-app" successfully rolled out
```

If the rollout is stuck (e.g., new pods fail their readiness probe), the command will eventually time out based on `progressDeadlineSeconds`.

### Check if a rollout has stalled

```bash
kubectl get deployment <name> -n <namespace>
# Look for: READY column — if ready < desired for more than progressDeadlineSeconds
kubectl describe deployment <name> -n <namespace>
# Look for: DeploymentReplicaSetFailed or ProgressDeadlineExceeded condition
```

---

## 3. Rollback to the Previous Version

The simplest rollback — reverts to the immediately preceding revision:

```bash
kubectl rollout undo deployment/<name> -n <namespace>
```

This performs a rolling replacement of pods, respecting `maxUnavailable` and `maxSurge`. The previous ReplicaSet is scaled back up while the current one is scaled down.

### Monitor the rollback

```bash
kubectl rollout status deployment/<name> -n <namespace>
kubectl get pods -n <namespace> -w
```

### Verify the image after rollback

```bash
kubectl get deployment <name> -n <namespace> \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Note: Undo increments the revision number

After `kubectl rollout undo`, the revision counter increments. If you were at revision 3 and roll back to revision 2, the new current revision is 4 (with the same spec as revision 2). This preserves the audit trail.

---

## 4. Rollback to a Specific Revision

Roll back to a specific historical revision by number:

```bash
kubectl rollout undo deployment/<name> -n <namespace> --to-revision=2
```

### Example workflow

```bash
# 1. List available revisions
kubectl rollout history deployment/payment-api -n production

# Output:
# REVISION  CHANGE-CAUSE
# 1         Deploy v1.0.0 — initial release
# 2         Deploy v1.1.0 — add retry logic
# 3         Deploy v1.2.0 — experimental cache layer  ← current (problematic)

# 2. Roll back to revision 1 (skip revision 2 which also has issues)
kubectl rollout undo deployment/payment-api -n production --to-revision=1

# 3. Confirm
kubectl rollout status deployment/payment-api -n production
kubectl rollout history deployment/payment-api -n production
# REVISION  CHANGE-CAUSE
# 1         Deploy v1.0.0 — initial release
# 2         Deploy v1.1.0 — add retry logic
# 3         Deploy v1.2.0 — experimental cache layer
# 4         Deploy v1.0.0 — initial release  ← restored, now current
```

### Rollback for other workload types

`kubectl rollout undo` works for:
- `Deployment`
- `StatefulSet`
- `DaemonSet`

It does **not** work for Jobs or CronJobs (those are immutable once created).

---

## 5. Helm Rollback

Helm tracks release history independently of Kubernetes Deployment revision history. Each `helm upgrade` creates a new release revision stored as a Secret in the target namespace.

### View Helm release history

```bash
helm history <release-name> -n <namespace>
```

Example output:
```
REVISION  UPDATED                   STATUS      CHART            APP VERSION  DESCRIPTION
1         Mon Apr 28 09:00:00 2026  superseded  my-app-1.0.0     1.0.0        Install complete
2         Mon Apr 28 14:30:00 2026  superseded  my-app-1.1.0     1.1.0        Upgrade complete
3         Tue Apr 29 08:00:00 2026  failed      my-app-1.2.0     1.2.0        Upgrade failed
4         Tue Apr 29 08:05:00 2026  deployed    my-app-1.1.0     1.1.0        Rollback to 2
```

### Rollback to the previous Helm revision

```bash
helm rollback <release-name> -n <namespace>
```

### Rollback to a specific Helm revision

```bash
helm rollback <release-name> <revision-number> -n <namespace>

# Example: rollback to revision 1
helm rollback payment-api 1 -n production
```

### Helm rollback with wait

```bash
helm rollback <release-name> <revision> -n <namespace> --wait --timeout 5m
```

`--wait` causes Helm to wait until all pods are ready before declaring success. `--timeout` sets the maximum wait time.

### Helm rollback recreates all resources

Unlike `kubectl rollout undo` (which only changes the pod template), `helm rollback` reinstates the entire set of Kubernetes resources from the target revision — including Services, ConfigMaps, RBAC, CRDs, etc. This is more comprehensive and safer for releases that changed non-Deployment resources.

### Check how many Helm revisions are retained

```bash
helm show chart <release-name> -n <namespace>
# Or set at install/upgrade time:
helm upgrade <release> <chart> --history-max 20
```

Default history max: 10 revisions.

---

## 6. GitOps Rollback

In GitOps environments, the Git repository is the source of truth. Rollback means reverting the Git state and letting the GitOps controller resync.

### ArgoCD Rollback

**Option A — Sync to a previous Git commit (via ArgoCD UI or CLI):**
```bash
# Get the ArgoCD application status and history
argocd app history <app-name>

# Rollback to a specific history ID
argocd app rollback <app-name> <history-id>
```

This does a one-time sync to that historical state but does not change the Git repo. On the next auto-sync, ArgoCD will drift back to the current HEAD unless auto-sync is disabled.

**Option B — Revert the Git commit (recommended):**
```bash
# In the Git repo
git revert <bad-commit-hash>
git push origin main
```

ArgoCD detects the new HEAD (the revert commit) and syncs. This preserves the full audit trail in Git history and keeps the GitOps invariant (Git = source of truth).

**Temporarily disable auto-sync during investigation:**
```bash
argocd app set <app-name> --sync-policy none
# ... investigate and fix ...
argocd app set <app-name> --sync-policy automated
```

### Flux Rollback

**Option A — Git revert:**
```bash
git revert <bad-commit-hash>
git push origin main
# Flux detects the new commit and reconciles
```

**Option B — Suspend and manually patch:**
```bash
# Suspend reconciliation while investigating
flux suspend kustomization <kustomization-name>

# Manually rollback via kubectl
kubectl rollout undo deployment/<name> -n <namespace>

# Resume when ready
flux resume kustomization <kustomization-name>
```

**Force immediate reconciliation:**
```bash
flux reconcile kustomization <kustomization-name> --with-source
```

### GitOps Rollback Principles

1. Never manually apply manifests to a GitOps-managed cluster without a plan to reflect the change in Git
2. Always revert via Git rather than `kubectl rollout undo` — the next sync would overwrite the manual rollback anyway
3. If a hotfix is urgent and Git PR takes too long, temporarily disable auto-sync, apply manually, then immediately open a PR to reflect the fix in Git

---

## 7. PodDisruptionBudget During Rollback

A PodDisruptionBudget (PDB) protects your application during voluntary disruptions — including rollbacks. Without a PDB, a rollback could take all pods offline simultaneously if `maxUnavailable` is set to 100%.

### PDB enforces availability during rollback

During `kubectl rollout undo` (which is a rolling update), the Deployment controller respects:
- `spec.strategy.rollingUpdate.maxUnavailable`: max pods unavailable during rollback
- The PDB: if terminating a pod would violate `minAvailable`, the rollback pauses until a new pod becomes Ready

### Example PDB for a 3-replica Deployment

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payment-api-pdb
  namespace: production
spec:
  minAvailable: 2   # always keep at least 2 pods up
  selector:
    matchLabels:
      app: payment-api
```

With `minAvailable: 2` and 3 replicas, at most 1 pod can be unavailable at any time. The rollback proceeds one pod at a time, ensuring service continuity.

### Check PDB status during rollback

```bash
kubectl get pdb -n <namespace>
# ALLOWED DISRUPTIONS column shows how many pods can currently be disrupted
kubectl describe pdb <pdb-name> -n <namespace>
```

### Helm respects PDB during rollback

Helm's rolling update strategy also respects PDBs. If `helm rollback` would violate a PDB, the rollback waits.

---

## 8. Preventing Bad Rollouts

Prevention is better than rollback. These mechanisms slow down or stop a bad rollout before it affects all pods.

### readinessProbe

The most important mechanism. The rolling update controller only marks a new pod as "available" (eligible to replace an old pod) once its readiness probe passes. If the probe never passes, the rollout stalls and triggers `ProgressDeadlineExceeded`.

Configure readiness probes to check real application health — not just that the process is running:
```yaml
readinessProbe:
  httpGet:
    path: /ready   # endpoint that checks DB connectivity, cache, dependencies
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 3
  successThreshold: 1
```

### minReadySeconds

How long a newly ready pod must remain ready before the controller considers it "stable" and proceeds to the next pod. Prevents a pod that passes readiness briefly and then fails from being counted as available.

```yaml
spec:
  minReadySeconds: 30   # wait 30s of continuous readiness before proceeding
```

### progressDeadlineSeconds

If the rollout does not make progress within this duration, the Deployment is marked as failed. The rollout does NOT automatically roll back — you must intervene manually or use an external rollout controller.

```yaml
spec:
  progressDeadlineSeconds: 300   # 5 minutes
```

Detect a stalled rollout:
```bash
kubectl rollout status deployment/<name> -n <namespace>
# Returns exit code 1 if deadline exceeded
```

### maxUnavailable and maxSurge

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0    # never reduce below desired replica count (safest)
      maxSurge: 1          # allow 1 extra pod during rollout
```

With `maxUnavailable: 0`, the rollout always has the full desired replica count available. The new pod must become Ready before an old pod is terminated.

### Example rolling-strategy.yml reference

See `core/workloads/deployment/rolling-strategy.yml` for a complete Deployment with all rollout safety settings configured.

---

## 9. Post-Rollback Verification Checklist

After completing a rollback, verify that the system has returned to a healthy state:

**Deployment state:**
- [ ] `kubectl rollout status deployment/<name>` reports success
- [ ] All desired replicas are Running and Ready: `kubectl get pods -n <namespace>`
- [ ] Correct image version is deployed: `kubectl get deployment <name> -o jsonpath='{.spec.template.spec.containers[0].image}'`

**Application health:**
- [ ] Health check endpoint returns 200: `curl https://<host>/health`
- [ ] Key functional endpoints are responding correctly
- [ ] Error rate in Grafana/Prometheus has returned to baseline
- [ ] P99 latency has returned to pre-incident levels

**Downstream dependencies:**
- [ ] External integrations (payment providers, third-party APIs) are not reporting errors
- [ ] Database connection pool is healthy (no exhaustion errors)
- [ ] Message queue depth has returned to normal (no backlog buildup)

**Kubernetes resources:**
- [ ] PDB shows correct `ALLOWED DISRUPTIONS`: `kubectl get pdb -n <namespace>`
- [ ] No `FailedScheduling` or `Evicted` events: `kubectl get events -n <namespace> --sort-by='.lastTimestamp'`
- [ ] HPA is within normal range: `kubectl get hpa -n <namespace>`

**Incident management:**
- [ ] Incident ticket updated with timeline and resolution
- [ ] Root cause identified and tracked in a post-mortem issue
- [ ] Fix for the bad release committed to Git and reviewed
- [ ] Monitoring alert that should have caught this reviewed and improved if needed
