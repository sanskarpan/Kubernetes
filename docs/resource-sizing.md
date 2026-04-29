# Kubernetes Resource Sizing Guide

Correctly sizing CPU and memory requests and limits is one of the most impactful decisions for cluster reliability, cost, and performance. This guide provides principles, patterns, and workload-specific formulas.

---

## Table of Contents

1. [Requests vs Limits](#1-requests-vs-limits)
2. [CPU Limits and Throttling](#2-cpu-limits-and-throttling)
3. [Memory: Setting Limits Equal to Requests](#3-memory-setting-limits-equal-to-requests)
4. [Measuring Baseline Usage](#4-measuring-baseline-usage)
5. [Sizing by Workload Type](#5-sizing-by-workload-type)
6. [QoS Classes and Eviction Priority](#6-qos-classes-and-eviction-priority)
7. [LimitRange Defaults](#7-limitrange-defaults)
8. [ResourceQuota at Namespace Level](#8-resourcequota-at-namespace-level)
9. [Vertical vs Horizontal Scaling](#9-vertical-vs-horizontal-scaling)
10. [Repository References](#10-repository-references)

---

## 1. Requests vs Limits

Understanding the distinction is foundational to correct Kubernetes resource management.

### Requests

A **request** is a scheduling guarantee. It answers: "What is the minimum amount of CPU/memory this container needs to function?"

Kubernetes uses requests to:
- **Schedule**: The scheduler sums up all pod requests on a node and only places a new pod if the node has enough allocatable capacity remaining.
- **Set relative priority**: Linux cgroups use CPU requests (`cpu.shares`) to determine how much CPU a container gets when multiple containers compete for the same CPU cycles.

If you set a CPU request too low, your pod might be scheduled on an already-crowded node and receive insufficient CPU under load. If you set it too high, pods waste allocatable capacity on nodes and the scheduler rejects pods unnecessarily.

### Limits

A **limit** is an enforcement boundary. It answers: "What is the maximum amount of CPU/memory this container can consume?"

What happens when limits are exceeded:
- **CPU limit exceeded**: The container is **throttled** — it cannot run until the next CFS period (100 ms default). The process is not killed. This can cause latency spikes that are difficult to diagnose.
- **Memory limit exceeded**: The container is **OOMKilled** (killed with SIGKILL, exit code 137). There is no graceful shutdown.

### The Scheduling Gap

Resources are scheduled based on requests, not limits. A pod can be scheduled onto a node that cannot support its limit. This is intentional — it enables overcommit. The downside: if too many containers simultaneously hit their limits, nodes run out of actual memory and evictions occur.

### Key formula

```
Node Allocatable = Node Capacity - OS overhead - Kubelet overhead - kube-reserved

Pod fits on node when:
  sum(all_pod_requests_on_node) + new_pod_request <= Node Allocatable
```

### Practical starting point

Begin with requests sized to the 50th percentile of observed usage. Set limits to the 95th–99th percentile of observed usage. Refine over time using VPA recommendations.

---

## 2. CPU Limits and Throttling

### Why CPU limits cause throttling

Linux enforces CPU limits using the CFS (Completely Fair Scheduler) bandwidth controller. It works as follows:

- Each container is allocated a quota: `cpu_limit × cfs_period_us` microseconds of CPU time per period (default period: 100 ms)
- If a container uses its entire quota before the period ends, it is throttled (cannot run) for the rest of the period
- Throttling can occur even when the node has plenty of idle CPU

**Example**: A container with a 0.5 CPU limit gets 50 ms of CPU time per 100 ms period. If the container needs a 70 ms burst to handle a request, it will be throttled for 20 ms — causing request latency even though the node has idle CPUs.

### How to detect CPU throttling

```bash
# Prometheus query — throttled ratio per container
sum(rate(container_cpu_cfs_throttled_seconds_total[5m])) by (pod, container)
/
sum(rate(container_cpu_cfs_periods_total[5m])) by (pod, container)
```

A throttle ratio above 20–25% indicates meaningful performance impact.

### When to omit CPU limits

For **latency-sensitive workloads** (web servers, APIs, databases), consider setting CPU requests without CPU limits. This allows the container to use spare CPU capacity on the node without artificial throttling.

Risks of omitting CPU limits:
- A noisy neighbor pod can consume all available CPU on a node
- Node CPU overcommit can degrade if many pods simultaneously spike

Mitigation: Use CPU requests accurately, monitor with Prometheus, and rely on the scheduler to spread load appropriately.

### Recommended CPU approach by workload type

| Workload Type | CPU Request | CPU Limit |
|--------------|------------|----------|
| Latency-sensitive web API | Set accurately | Omit or set high (3–4×) |
| Background batch job | Set low | Set (burst acceptable) |
| Database (PostgreSQL, MySQL) | Set accurately | Omit (kernel scheduler handles) |
| Sidecar (Envoy, log agent) | Set low | Set (predictable usage) |

---

## 3. Memory: Setting Limits Equal to Requests

### Why memory behaves differently from CPU

Memory cannot be throttled — if a process needs more memory than is available and the limit is reached, the Linux OOM killer terminates it immediately. There is no "slow down and wait" behavior as with CPU.

### The Guaranteed QoS pattern for memory

Set memory requests equal to limits for all production stateful workloads:

```yaml
resources:
  requests:
    memory: "512Mi"
  limits:
    memory: "512Mi"   # equal to request
```

**Why this matters**:
1. **Eviction safety**: The pod gets `Guaranteed` QoS class, which is the last to be evicted under node memory pressure.
2. **Predictable behavior**: The container always has exactly 512Mi available. If the application exceeds this, it OOMKills — a clear signal to tune the limit upward, rather than a confusing eviction at unpredictable times.
3. **Accurate scheduling**: The scheduler reserves exactly what the pod will use, preventing overcommit.

### When requests < limits (Burstable) is acceptable

- **Caching layers** that can tolerate eviction and rebuild their cache
- **Development workloads** where occasional OOMKill is acceptable
- **Batch jobs** where a single retry due to OOMKill is cheap

### Memory limit sizing rule

Start with: `limit = 1.5× observed_peak_memory`

Peak memory can be read from Prometheus: `container_memory_working_set_bytes` (excludes reclaimable page cache — more accurate than `container_memory_usage_bytes`).

Refine using VPA recommendation mode over 7–14 days of production traffic.

---

## 4. Measuring Baseline Usage

Never guess resource sizes. Measure.

### kubectl top (real-time)

```bash
# Current node usage
kubectl top nodes

# Current pod usage (all containers in namespace)
kubectl top pods -n <namespace> --containers

# Sort by memory
kubectl top pods -n <namespace> --sort-by=memory
```

`kubectl top` requires the Metrics Server to be installed. It provides point-in-time data — insufficient for sizing decisions. Use it for quick sanity checks.

### Prometheus and Grafana (recommended)

Key Prometheus metrics for resource sizing:

```promql
# CPU usage over 1 hour (average)
avg_over_time(
  rate(container_cpu_usage_seconds_total{namespace="production", container="my-app"}[5m])
[1h:5m])

# CPU usage p95 over 7 days
quantile_over_time(0.95,
  rate(container_cpu_usage_seconds_total{container="my-app"}[5m])
[7d:5m])

# Memory working set (peak over 7 days)
max_over_time(
  container_memory_working_set_bytes{namespace="production", container="my-app"}
[7d])

# CPU throttle ratio
sum(rate(container_cpu_cfs_throttled_seconds_total{container="my-app"}[5m]))
/
sum(rate(container_cpu_cfs_periods_total{container="my-app"}[5m]))
```

Grafana has built-in Kubernetes dashboards (dashboard IDs 6417, 13646) that visualize resource usage, requests, limits, and throttling.

### VPA Recommendation Mode

The Vertical Pod Autoscaler in recommendation mode (`updateMode: "Off"`) collects metrics and computes right-sized requests/limits without modifying pods:

```bash
kubectl get vpa -n <namespace>
kubectl describe vpa <vpa-name> -n <namespace>
# Look for: Recommendation section — Lower Bound, Target, Upper Bound
```

VPA recommendations are based on observed usage histogram over the configured `historyLength`. Use `Target` as your request value and `Upper Bound` as your limit value. See `platform/autoscaling/vpa/vpa-auto.yml`.

---

## 5. Sizing by Workload Type

### 5.1 Web Server / REST API (stateless)

**Characteristics**: Bursty CPU usage per request; relatively stable memory; horizontally scalable.

**Strategy**: Size for p95 request load. Scale with HPA. Allow CPU burst (no CPU limits or high limit multiplier).

```yaml
# Starting point for a medium-traffic Go/Node.js API
resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    memory: "512Mi"   # 2× request; no CPU limit
```

**Formula**: `cpu_request = avg_rps × avg_cpu_per_request × 1.3 (safety factor)`

### 5.2 Database (PostgreSQL, MySQL)

**Characteristics**: Sustained CPU during query processing; memory critical for buffer pool/shared buffers; cannot easily scale horizontally.

**Strategy**: Generous memory requests (size for buffer pool needs); no CPU limits; use VPA for right-sizing; Guaranteed QoS.

```yaml
# PostgreSQL with 4GB shared_buffers
resources:
  requests:
    cpu: "1"
    memory: "6Gi"   # shared_buffers (4Gi) + connections + overhead
  limits:
    memory: "6Gi"   # equal to request — Guaranteed QoS
```

**Formula**: `memory_request = shared_buffers + max_connections × work_mem + 512Mi overhead`

### 5.3 Batch Job

**Characteristics**: CPU and memory spike during processing; no latency constraints; can tolerate termination and retry.

**Strategy**: Size for peak usage; set CPU limits (burst acceptable); tight memory limits (OOMKill triggers retry).

```yaml
# Data processing job
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "2"       # allow burst during intensive processing
    memory: "2Gi"  # hard limit — if exceeded, retry the job
```

### 5.4 Background Worker / Queue Consumer

**Characteristics**: Moderate steady-state CPU; memory grows with queue backlog; scales with message volume.

**Strategy**: Size for steady-state; let HPA scale replicas based on queue depth (custom metric via Prometheus Adapter or KEDA).

```yaml
# Celery/Sidekiq worker
resources:
  requests:
    cpu: "200m"
    memory: "512Mi"
  limits:
    cpu: "500m"
    memory: "768Mi"
```

### 5.5 Sidecar (Service Mesh Proxy, Log Agent)

**Characteristics**: Very predictable, low usage; must not impact primary container scheduling.

```yaml
# Envoy sidecar
resources:
  requests:
    cpu: "10m"
    memory: "64Mi"
  limits:
    cpu: "100m"
    memory: "128Mi"
```

Keep sidecar requests as low as accurately possible — they are charged against every pod's scheduling footprint.

---

## 6. QoS Classes and Eviction Priority

Kubernetes assigns each pod a QoS class based on how requests and limits are set. This class determines eviction priority when a node is under memory pressure.

### Guaranteed

**Condition**: Every container in the pod has equal and non-zero CPU and memory requests and limits.

**Eviction priority**: Last to be evicted. The kubelet will not evict a Guaranteed pod unless no other pod can be evicted.

**Best for**: Databases, critical services, production stateful workloads.

```yaml
# Guaranteed QoS
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "500m"   # must equal request
    memory: "1Gi" # must equal request
```

### Burstable

**Condition**: At least one container has a request or limit set, but they are not all equal.

**Eviction priority**: Evicted after BestEffort. Among Burstable pods, those using more memory relative to their request are evicted first.

**Best for**: Web servers, workers, applications that can tolerate occasional disruption.

### BestEffort

**Condition**: No requests or limits set on any container.

**Eviction priority**: First to be evicted. Also scheduled on any node without reservation, so they may receive very little CPU on busy nodes.

**Best for**: Development, low-priority background tasks.

### Eviction sequence

```
Under memory pressure on a node:

1. Evict BestEffort pods (no requests set)
2. Evict Burstable pods (highest memory usage relative to request first)
3. Evict Guaranteed pods (last resort)
4. If Guaranteed pods still violate hard limits → OOMKill by Linux kernel
```

---

## 7. LimitRange Defaults

A `LimitRange` policy applies default resource requests and limits to pods/containers that don't specify them, and optionally enforces minimum/maximum bounds. See `core/storage/limitrange.yml`.

### Why LimitRanges matter

Without a LimitRange, pods with no resource requests get BestEffort QoS. They consume unbounded node resources and are the first to be evicted. A LimitRange ensures every pod in a namespace has at least some baseline resource definition.

### Example LimitRange

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: production
spec:
  limits:
    - type: Container
      default:           # applied when no limit is set
        cpu: "500m"
        memory: "256Mi"
      defaultRequest:    # applied when no request is set
        cpu: "100m"
        memory: "128Mi"
      max:               # cannot set limit higher than this
        cpu: "4"
        memory: "8Gi"
      min:               # cannot set request lower than this
        cpu: "10m"
        memory: "32Mi"
```

### LimitRange application

LimitRange defaults are applied at pod admission time. They are only applied to containers that have no explicit requests/limits set — they do not override values already set in the pod spec.

---

## 8. ResourceQuota at Namespace Level

A `ResourceQuota` caps the total resource consumption and object count for an entire namespace. It prevents a single team or application from consuming disproportionate cluster capacity.

### CPU and memory quotas

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "20"       # total CPU requests across all pods
    requests.memory: "40Gi"  # total memory requests
    limits.cpu: "40"
    limits.memory: "80Gi"
    pods: "100"              # max pod count
    services: "20"
    persistentvolumeclaims: "30"
    requests.storage: "2Ti"  # total PVC storage
```

### Quota enforcement

When a quota is set:
- Any pod creation that would exceed the quota is rejected with a 403 error
- Pods **must** have resource requests set if a quota on requests is configured — otherwise admission fails
- This is why LimitRange defaults and ResourceQuota are typically deployed together

### Quota by QoS class

You can scope quotas by QoS class:

```yaml
spec:
  hard:
    guaranteed.cpu: "10"          # limit Guaranteed class CPU
    requests.cpu: "20"            # overall limit
    burstable.memory: "20Gi"      # limit Burstable class memory
```

This prevents teams from claiming unlimited Guaranteed QoS resources.

---

## 9. Vertical vs Horizontal Scaling

### Decision framework

```
Is the workload stateless?
  │
  ├─► Yes → Can it handle more instances safely?
  │           ├─► Yes → Horizontal scaling (HPA) preferred
  │           │           → Scale replicas based on CPU, memory, or custom metrics
  │           └─► No (singleton constraint) → Vertical scaling (VPA)
  │
  └─► No (stateful: database, queue) →
        Is the bottleneck CPU or memory?
          ├─► Memory → Vertical scaling (increase memory requests/limits)
          ├─► CPU → Vertical scaling first; consider read replicas for horizontal read scaling
          └─► Connection count → Application-level pooling (PgBouncer) before scaling the DB
```

### HPA (Horizontal Pod Autoscaler)

Best for stateless workloads with predictable load patterns. Scales replicas in/out. Does not require pod restarts.

```yaml
# See platform/autoscaling/hpa/hpa-cpu-memory.yml
spec:
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60   # target 60% CPU utilization
```

**HPA requires resource requests**: HPA calculates utilization as `actual_usage / request`. If requests are not set, HPA cannot compute utilization and will not scale.

### VPA (Vertical Pod Autoscaler)

Best for stateful workloads that cannot scale horizontally, or for right-sizing any workload automatically.

**Modes**:
- `Off`: Compute recommendations only (safe for production, manual apply)
- `Initial`: Set resources at pod creation only (no live adjustment)
- `Auto`: Evict and restart pods with updated resources (use with care on stateful workloads)
- `Recreate`: Same as Auto but only on pod restart

```bash
# View VPA recommendations
kubectl describe vpa <vpa-name> -n <namespace>
```

**VPA + HPA conflict**: Do not use VPA `Auto`/`Recreate` mode with HPA on CPU or memory simultaneously — they fight each other. Use VPA for memory right-sizing and HPA on CPU, or use HPA on custom metrics (not CPU) with VPA managing CPU/memory.

### Cost vs performance trade-offs

| Approach | Cost efficiency | Performance | Operational complexity |
|---------|----------------|-------------|----------------------|
| Overprovisioned (no sizing) | Low | High (no throttle) | Low |
| Right-sized requests, no limits | High | High | Medium |
| Right-sized requests + limits | High | Medium (potential throttle) | Medium |
| VPA Auto | Very high | Medium | High |
| HPA + VPA (custom metrics) | Highest | High | High |

---

## 10. Repository References

| File | Description |
|------|-------------|
| `platform/autoscaling/hpa/hpa-cpu-memory.yml` | HPA example: CPU + memory targets |
| `platform/autoscaling/hpa/hpa-with-behavior.yml` | HPA with custom scale-up/scale-down behavior |
| `platform/autoscaling/vpa/vpa-auto.yml` | VPA in auto mode |
| `core/storage/limitrange.yml` | Namespace LimitRange defaults |
| `core/workloads/deployment/nginx-deployment.yml` | Deployment with resource requests/limits |

### Quick reference: resource sizing command

```bash
# See current requests/limits for all pods in a namespace
kubectl get pods -n <namespace> -o custom-columns=\
"NAME:.metadata.name,\
CPU_REQ:.spec.containers[0].resources.requests.cpu,\
MEM_REQ:.spec.containers[0].resources.requests.memory,\
CPU_LIM:.spec.containers[0].resources.limits.cpu,\
MEM_LIM:.spec.containers[0].resources.limits.memory"

# Compare to actual usage
kubectl top pods -n <namespace> --containers
```
