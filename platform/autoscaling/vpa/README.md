# Vertical Pod Autoscaler (VPA) — Guide

## Overview

VPA automatically adjusts the CPU and memory **requests** (and optionally limits) for pods based on observed historical usage. Unlike HPA, which adds more replicas, VPA makes each individual pod more (or less) resource-efficient.

VPA is a separate project from core Kubernetes and requires its own installation. It is not bundled with the Kubernetes control plane.

---

## Update Modes

VPA operates in one of four modes controlled by `updatePolicy.updateMode`:

### `Off` — Recommendations Only (Start Here)

VPA observes resource usage and writes recommendations to the VPA object's `status.recommendation` field, but **makes no changes to running pods**.

```bash
kubectl describe vpa -n workloads nginx-vpa
# Look for: Status > Recommendation > Container Recommendations
```

**Use `Off` mode to:**
- Discover right-sized requests for a workload without risk
- Build a baseline before enabling automatic updates
- Use in CI/CD pipelines to validate resource requests in PRs

### `Initial` — Set on Pod Creation Only

VPA sets resource requests when pods are **first created** (or recreated after a deployment rollout), but never modifies running pods.

**Use `Initial` mode for:**
- Deployments that roll frequently (VPA gets to set values on each rollout)
- Workloads where you can't tolerate pod disruption
- Blue/green deployments where new pods always start fresh

### `Auto` — Full Automation

VPA monitors resource usage and when it detects that a pod's requests diverge significantly from the recommendation, it **evicts the pod** and lets the scheduler recreate it with updated resource requests.

**Important caveats for `Auto` mode:**
- Pod evictions cause brief disruption — ensure PodDisruptionBudgets (PDBs) are configured
- VPA does not respect `minReplicas` on your Deployment directly — it evicts one pod at a time, but if your deployment has only 1 replica, that pod will be evicted (brief downtime)
- VPA will not evict pods that would violate a PodDisruptionBudget, so PDBs are your safety net

**Use `Auto` mode for:**
- Batch jobs and non-user-facing workloads
- Single-tenant workloads where brief restarts are acceptable
- Stateless services with multiple replicas and PDBs configured

### `Recreate` (Legacy alias for Auto behavior pre-1.0)

Behaves like `Auto` but was the original name. Use `Auto` in modern VPA versions.

---

## How VPA Interacts with HPA

**The golden rule: do not let VPA and HPA control the same resource dimension.**

| Scenario | Safe? | Notes |
|---------|-------|-------|
| VPA `Off` + HPA on CPU | ✅ Yes | VPA advises, HPA controls replicas. Manually apply VPA recommendations. |
| VPA `Initial` + HPA on CPU | ⚠️ Caution | VPA sets values at pod creation; HPA then controls replicas. Can work if VPA recommendations are stable. |
| VPA `Auto` + HPA on CPU | ❌ No | VPA changes requests → HPA sees different utilization → replica thrashing |
| VPA `Auto` + HPA on custom metrics (RPS, queue depth) | ✅ Yes | No overlap — VPA handles resource requests, HPA handles replica count on non-resource metric |

**Recommended production pattern:**
1. Run VPA in `Off` mode for 1–2 weeks to gather recommendations
2. Apply the recommended values to your Deployment YAML manually
3. Enable HPA on CPU/memory with the now-correct requests as baseline
4. Keep VPA in `Off` mode for ongoing monitoring

---

## VPA Installation

VPA is NOT installed by default. It requires separate installation from the [kubernetes/autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) repository.

### Option 1: Helm (Recommended)

```bash
helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm repo update
helm upgrade --install vpa fairwinds-stable/vpa \
  --namespace kube-system \
  --set recommender.enabled=true \
  --set updater.enabled=true \
  --set admissionController.enabled=true
```

### Option 2: Official Scripts

```bash
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh
```

### Verify Installation

```bash
kubectl get pods -n kube-system | grep vpa
# Expect three pods:
#   vpa-recommender-xxx      - reads metrics, computes recommendations
#   vpa-updater-xxx          - evicts pods that need resource updates (Auto mode)
#   vpa-admission-controller-xxx - mutates pod specs on creation (Initial/Auto)
```

**Note:** VPA requires Metrics Server to be installed — same prerequisite as HPA.

---

## Reading VPA Recommendations

After a VPA object exists in `Off` mode and the recommender has had time to observe the workload (minimum 15 minutes, ideally 24+ hours for meaningful data):

```bash
kubectl describe vpa nginx-vpa -n workloads
```

Look for the `Status > Recommendation` section:

```
Status:
  Recommendation:
    Container Recommendations:
      Container Name: nginx
      Lower Bound:
        Cpu:     25m
        Memory:  128Mi
      Target:
        Cpu:     50m        ← Set this as resources.requests.cpu
        Memory:  256Mi      ← Set this as resources.requests.memory
      Uncapped Target:
        Cpu:     50m
        Memory:  200Mi
      Upper Bound:
        Cpu:     200m
        Memory:  512Mi
```

**Fields explained:**

| Field | Meaning | Action |
|-------|---------|--------|
| `Target` | Optimal value based on observed usage | Apply this to your Deployment |
| `Lower Bound` | 5th percentile — minimum safe value | Use as `resources.requests` floor |
| `Upper Bound` | 95th percentile — maximum observed | Use to validate `resources.limits` |
| `Uncapped Target` | Target ignoring `resourcePolicy` bounds | Diagnostics only |

---

## Resource Policy — Bounding VPA Recommendations

Use `resourcePolicy.containerPolicies` to prevent VPA from recommending values outside safe ranges:

```yaml
resourcePolicy:
  containerPolicies:
    - containerName: nginx
      minAllowed:
        cpu: 50m
        memory: 64Mi
      maxAllowed:
        cpu: 2
        memory: 2Gi
      controlledResources: ["cpu", "memory"]
```

**Why set bounds?**
- `minAllowed`: Prevents VPA from setting requests so low that resource pressure causes OOMKills or CPU throttling
- `maxAllowed`: Prevents VPA from requesting more resources than a single node can provide (making the pod unschedulable)

---

## VPA in Production: Checklist

- [ ] VPA recommender, updater, and admission-controller are all running
- [ ] Metrics Server is installed and `kubectl top pods` works
- [ ] Start with `updateMode: Off` — observe recommendations for at least 24 hours
- [ ] Set `minAllowed` and `maxAllowed` in `resourcePolicy` to bound recommendations
- [ ] Configure PodDisruptionBudgets before enabling `Auto` mode
- [ ] Do not enable `Auto` mode if HPA is also scaling on CPU/memory for the same workload
- [ ] Monitor VPA events: `kubectl get events -n workloads --field-selector reason=EvictedByVPA`
