# Resource Quotas and LimitRanges

## Overview

In a multi-tenant Kubernetes cluster, multiple teams or applications share the same compute resources. Without guardrails, one namespace can consume all cluster resources — starving other tenants. **ResourceQuota** and **LimitRange** are the two Kubernetes-native tools to enforce fair sharing.

**Apply both in every namespace as a pair.**

---

## Why ResourceQuota is Essential for Multi-Tenant Clusters

### The noisy neighbor problem

Without quotas, a single misconfigured deployment (e.g., a Deployment with 1000 replicas, or pods with `resources.requests.memory: 100Gi`) can exhaust a node's allocatable resources. Other pods on that node or cluster get evicted or become unschedulable.

### What ResourceQuota enforces

ResourceQuota sets **per-namespace** upper bounds on:
- Total CPU and memory requests/limits
- Number of specific object types (Pods, Services, PVCs, ConfigMaps, Secrets)
- Storage request totals and PVC count
- Object count quotas for LoadBalancers and NodePorts (which are cluster-wide resources)

When a namespace has an active ResourceQuota, **all pods in that namespace must have resource requests set**. If a pod spec omits `resources.requests`, admission is denied. This is why LimitRange (which sets defaults) must be deployed alongside ResourceQuota.

---

## LimitRange vs ResourceQuota

| Feature | LimitRange | ResourceQuota |
|---------|-----------|---------------|
| Scope | Per-pod or per-container | Per-namespace aggregate |
| Enforces | Min/max/default for individual containers | Total consumption across all objects |
| Auto-injects defaults | Yes — fills in missing requests/limits | No |
| Prevents unbounded single pod | Yes | No (quota limits total, not individual) |

### LimitRange sets defaults

Without a LimitRange, pods without `resources.requests` would be rejected by ResourceQuota (because quota requires requests to be set). LimitRange automatically injects default requests and limits for containers that don't specify them.

LimitRange also sets maximums — a single container cannot request more than `max.cpu` or `max.memory` even if the namespace quota still has headroom.

---

## Object Count Quotas

ResourceQuota can limit the number of Kubernetes objects in a namespace:

```yaml
count/pods: "50"              # At most 50 pods
count/services: "20"          # At most 20 services
count/services.nodeports: "0" # Disallow NodePort services entirely
count/services.loadbalancers: "2"  # At most 2 LoadBalancer services
count/persistentvolumeclaims: "10"
count/configmaps: "50"
count/secrets: "30"
```

This prevents accidental (or malicious) resource sprawl that could exhaust ETCD storage or cloud provider quotas (e.g., load balancer IPs).

### Scoped quotas

ResourceQuota supports `scopeSelector` to apply different limits to different priority classes:

```yaml
scopeSelector:
  matchExpressions:
    - operator: In
      scopeName: PriorityClass
      values: [high-priority]
```

This lets you reserve burst capacity for high-priority jobs while limiting best-effort workloads more strictly.

---

## Storage Quotas

```yaml
requests.storage: 100Gi          # Total PVC storage across all PVCs
persistentvolumeclaims: "10"     # Number of PVCs
<storageclass>.storageclass.storage.k8s.io/requests.storage: 50Gi  # Per-StorageClass
```

Storage quotas are important in clusters with expensive storage classes (e.g., SSD-backed, replicated storage). Cap per-StorageClass usage to prevent one team from consuming all fast storage.

---

## Recommended Workflow for New Namespaces

1. Create the namespace
2. Apply ResourceQuota and LimitRange (from `namespace-quota.yml`)
3. Apply NetworkPolicy (default-deny + allowlist)
4. Apply RBAC (Role + RoleBinding for the owning team)
5. Apply PSA labels (pod-security.kubernetes.io/enforce: restricted)

These five steps form the complete namespace bootstrap for a production multi-tenant cluster.

---

## Monitoring Quota Usage

```bash
# View quota usage in a namespace
kubectl describe quota -n <namespace>

# Example output:
# Name:            namespace-quota
# Namespace:       workloads
# Resource         Used   Hard
# --------         ----   ----
# limits.memory    2Gi    8Gi
# pods             12     50
# requests.cpu     800m   4
# requests.memory  2Gi    8Gi

# View LimitRange in effect
kubectl describe limitrange -n <namespace>

# Watch quota in real time (useful during load tests)
watch kubectl describe quota -n <namespace>
```

---

## Common Mistakes

### 1. Quota without LimitRange

If ResourceQuota requires resource requests, but pods don't specify them and there's no LimitRange to inject defaults, all pod creation will fail with:
```
Error from server (Forbidden): pods "my-pod" is forbidden: failed quota: namespace-quota:
  must specify requests.cpu for: my-container
```

**Fix:** Always deploy LimitRange alongside ResourceQuota.

### 2. LimitRange max too low

If `max.memory: 256Mi` is set but your application genuinely needs 512Mi, pods will be rejected. Review application resource usage with VPA in `Off` mode before setting LimitRange max values.

### 3. Quota set too tight at launch

Teams often underprovision quotas initially. Set quotas generously at first and tighten based on actual usage (visible via `kubectl describe quota`). Don't restrict to the point of blocking legitimate workloads.

### 4. Forgetting to update quota after team growth

Quotas should be reviewed quarterly or when teams onboard new services. Track quota utilization in Grafana (kube-state-metrics exposes `kube_resourcequota` metrics).
