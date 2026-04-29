# Node Affinity and Pod Anti-Affinity

## Overview

Affinity rules allow pods to express **preferences or requirements** about which nodes they can run on and whether they should be co-located or spread across nodes/zones. Unlike `nodeSelector` (simple key=value matching), affinity rules support operators (`In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`) and can be either hard requirements or soft preferences.

---

## Node Affinity

Node affinity controls which nodes a pod **can be scheduled on**, based on node labels.

### `requiredDuringSchedulingIgnoredDuringExecution` (Hard / Required)

The pod **will not be scheduled** on a node unless it matches the rule. If no matching node exists, the pod stays in `Pending`.

The `IgnoredDuringExecution` suffix means: if a node's labels change after a pod is already running there, the pod is **not evicted** (execution is not re-evaluated). This is the only type of node affinity currently implemented in stable Kubernetes.

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: disk
              operator: In
              values: [ssd]  # Only schedule on nodes labeled disk=ssd
```

Use for: Pod absolutely requires specific hardware (SSD, GPU, high-memory nodes, specific architecture).

### `preferredDuringSchedulingIgnoredDuringExecution` (Soft / Preferred)

The scheduler **tries to satisfy** the rule but will place the pod on a non-matching node if necessary. Each preference has a `weight` (1–100) — higher weight means stronger preference.

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: [us-east-1a]  # Prefer zone us-east-1a, but not required
      - weight: 20
        preference:
          matchExpressions:
            - key: node-type
              operator: In
              values: [compute-optimized]
```

Use for: Placement hints that improve performance or cost, but don't break the workload if unmet.

### Multiple `nodeSelectorTerms` — OR Logic

Multiple entries in `nodeSelectorTerms` are **OR**'ed — any one match is sufficient:

```yaml
nodeSelectorTerms:
  - matchExpressions:  # Matches nodes in us-east-1a with SSD...
      - key: topology.kubernetes.io/zone
        operator: In
        values: [us-east-1a]
      - key: disk
        operator: In
        values: [ssd]
  - matchExpressions:  # ...OR nodes in us-east-1b with any disk
      - key: topology.kubernetes.io/zone
        operator: In
        values: [us-east-1b]
```

Multiple `matchExpressions` within a single `nodeSelectorTerms` entry are **AND**'ed.

---

## Pod Affinity and Anti-Affinity

While node affinity selects nodes by node labels, pod affinity/anti-affinity selects nodes based on **what other pods are already running there**.

### Pod Anti-Affinity — Spreading Pods for HA

Pod anti-affinity ensures pods of the same application are distributed across failure domains (nodes, zones). This is essential for high availability.

```yaml
affinity:
  podAntiAffinity:
    # Hard: NEVER place two pods with app=frontend on the same zone
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: frontend
        topologyKey: topology.kubernetes.io/zone

    # Soft: PREFER not placing two pods on the same node
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: frontend
          topologyKey: kubernetes.io/hostname
```

**topologyKey** defines the failure domain:

| `topologyKey` value | Failure domain |
|---------------------|---------------|
| `kubernetes.io/hostname` | Individual node |
| `topology.kubernetes.io/zone` | Availability zone |
| `topology.kubernetes.io/region` | Cloud region |

### Why Pod Anti-Affinity is Essential for HA

Without pod anti-affinity, the scheduler may place all replicas of a deployment on the same node. If that node fails (hardware failure, kernel panic, maintenance drain), all replicas go down simultaneously. Pod anti-affinity with `topologyKey: kubernetes.io/hostname` guarantees at most one replica per node.

For true multi-zone HA, use `topologyKey: topology.kubernetes.io/zone` — this spreads replicas across availability zones so a zone failure doesn't take down the service.

### Pod Affinity — Co-location

Pod affinity places pods **near** other pods — on the same node or zone. Use sparingly, as it can create scheduling bottlenecks.

```yaml
affinity:
  podAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 50
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: redis-cache
          topologyKey: kubernetes.io/hostname
          # Place this pod on the same node as redis-cache pods (reduces latency)
```

---

## Common Node Labels

These labels are automatically applied by cloud provider node groups and Kubernetes itself:

| Label | Example Value | Source |
|-------|--------------|--------|
| `kubernetes.io/hostname` | `ip-10-0-1-42.ec2.internal` | Kubelet |
| `kubernetes.io/arch` | `amd64`, `arm64` | Kubelet |
| `kubernetes.io/os` | `linux`, `windows` | Kubelet |
| `topology.kubernetes.io/zone` | `us-east-1a` | Cloud provider |
| `topology.kubernetes.io/region` | `us-east-1` | Cloud provider |
| `node.kubernetes.io/instance-type` | `m5.xlarge` | Cloud provider |
| `node-role.kubernetes.io/control-plane` | `` (empty) | kubeadm |

For custom node pools, add your own labels:
```bash
kubectl label node node1 disk=ssd node-tier=high-memory
```

---

## Topology Spread Constraints (Modern Alternative)

For spreading pods evenly, [TopologySpreadConstraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) (stable since 1.24) is a simpler, more powerful alternative to pod anti-affinity:

```yaml
topologySpreadConstraints:
  - maxSkew: 1                                  # Allow at most 1 pod difference between domains
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule            # Hard: or ScheduleAnyway for soft
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: frontend
```

Consider using `topologySpreadConstraints` alongside or instead of pod anti-affinity for new workloads.

---

## Operators Reference

| Operator | Description |
|----------|-------------|
| `In` | Label value must be in the provided list |
| `NotIn` | Label value must not be in the provided list |
| `Exists` | Label key must exist (any value) |
| `DoesNotExist` | Label key must not exist |
| `Gt` | Label value (integer) must be greater than provided value |
| `Lt` | Label value (integer) must be less than provided value |

---

## Useful Commands

```bash
# View labels on all nodes
kubectl get nodes --show-labels

# Label a node (required for affinity rules referencing custom labels)
kubectl label node node1 disk=ssd

# Remove a label
kubectl label node node1 disk-

# Check why a pod is Pending (often affinity/taint issues)
kubectl describe pod <pod-name> -n <namespace>
# Look for Events — "didn't match affinity rules" or "had taints that pod didn't tolerate"

# Test scheduling without actually creating the pod
kubectl create deployment test --image=nginx --dry-run=server -o yaml
```
