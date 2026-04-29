# Taints and Tolerations

## Overview

Taints and tolerations work together to control which pods can be **scheduled onto** (and remain on) which nodes. Taints are applied to **nodes**; tolerations are applied to **pods**.

A taint on a node **repels** pods that do not have a matching toleration. A toleration on a pod **permits** it to be scheduled on a tainted node — but does not guarantee placement (that's what node affinity is for).

**Mental model:** A taint is a "keep out" sign on a node. A toleration is the key that unlocks it.

---

## Taint Effects

### `NoSchedule`

New pods **will not be scheduled** on the node unless they have a matching toleration. Pods already running on the node are **not affected**.

```bash
kubectl taint nodes node1 dedicated=database:NoSchedule
```

Use case: Reserve a node for database pods. Existing pods won't be evicted, but no new non-database pods can land there.

### `PreferNoSchedule`

The scheduler **tries to avoid** placing pods on the node, but will do so if there is no other option. Soft version of `NoSchedule`.

```bash
kubectl taint nodes node1 experimental=true:PreferNoSchedule
```

Use case: Mark nodes running experimental software. The scheduler prefers other nodes but won't block pods if no alternatives exist.

### `NoExecute`

The most aggressive effect:
1. New pods **will not be scheduled** on the node (same as `NoSchedule`)
2. Existing pods **without** a matching toleration are **evicted immediately**
3. Existing pods **with** a matching toleration remain running

```bash
kubectl taint nodes node1 node.kubernetes.io/not-ready:NoExecute
```

You can combine `NoExecute` with `tolerationSeconds` to allow pods to remain temporarily before eviction:
```yaml
tolerations:
  - key: "node.kubernetes.io/not-ready"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 300  # Stay up to 5 minutes before eviction
```

This is actually how Kubernetes implements node failure handling — the node controller automatically adds `NoExecute` taints when a node becomes unreachable, and pods with `tolerationSeconds` get a grace period before being rescheduled.

---

## How Tolerations Work

A toleration matches a taint when **all specified fields match**:

```yaml
tolerations:
  - key: dedicated          # Must match taint key
    operator: Equal         # Equal: value must match; Exists: any value matches
    value: database         # Must match taint value (only with Equal operator)
    effect: NoSchedule      # Must match taint effect (omit to match all effects)
```

### Operators

| Operator | Meaning | When to use |
|----------|---------|-------------|
| `Equal` | key=value must both match | Specific dedicated node pools |
| `Exists` | key must exist (any value) | Catch-all for a taint key |

### Matching all taints with a key

```yaml
tolerations:
  - operator: Exists  # No key or value — matches ALL taints on a node
```

**Warning:** This pattern (no key, `Exists`) tolerates every taint on every node. Only appropriate for system daemons like CNI plugins or node-local monitoring agents.

---

## Common Use Cases

### 1. Dedicated Nodes for Databases

Reserve high-memory, high-IO nodes exclusively for database pods:

```bash
# Taint the node
kubectl taint nodes db-node-1 dedicated=database:NoSchedule

# Verify
kubectl describe node db-node-1 | grep Taint
```

Database pods get a matching toleration. All other pods cannot schedule there.

### 2. GPU Nodes

GPU nodes are expensive. Prevent non-GPU workloads from occupying them:

```bash
kubectl taint nodes gpu-node-1 nvidia.com/gpu=present:NoSchedule
```

ML training pods tolerate this taint. Regular web servers don't, so they schedule on cheaper CPU nodes.

### 3. System Daemons (DaemonSets)

Core infrastructure DaemonSets (CNI, log forwarders, monitoring agents) must run on every node, including nodes with taints. They use broad `Exists` tolerations:

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
```

Kubernetes automatically adds these to critical system DaemonSets.

### 4. Spot/Preemptible Nodes

Mark spot instances so that only workloads that can tolerate interruption run there:

```bash
kubectl taint nodes spot-node-1 cloud.google.com/gke-spot=true:NoSchedule
```

Batch jobs and stateless workers tolerate it; stateful services don't.

---

## Effect of `NoExecute` on Running Pods

| Pod Status | Has Matching Toleration? | `tolerationSeconds` set? | Outcome |
|---|---|---|---|
| Running | No | N/A | Evicted immediately |
| Running | Yes | No | Stays running indefinitely |
| Running | Yes | Yes (e.g., 300) | Stays running for up to 300s, then evicted |

**Built-in Kubernetes taints using `NoExecute`:**

| Taint | Added when |
|-------|-----------|
| `node.kubernetes.io/not-ready` | Node fails readiness check |
| `node.kubernetes.io/unreachable` | Node controller loses contact with node |
| `node.kubernetes.io/memory-pressure` | Node is under memory pressure |
| `node.kubernetes.io/disk-pressure` | Node is under disk pressure |
| `node.kubernetes.io/pid-pressure` | Node is under PID pressure |
| `node.kubernetes.io/network-unavailable` | Node's network is not configured |
| `node.kubernetes.io/unschedulable` | Node is cordoned |

All pods running on Kubernetes automatically have tolerations for `not-ready` and `unreachable` with a `tolerationSeconds` of 300 (configurable via `--default-not-ready-toleration-seconds` on the scheduler).

---

## Taints vs Node Affinity

| Feature | Taints + Tolerations | Node Affinity |
|---------|---------------------|--------------|
| Who defines constraint | Node (taint) + Pod (toleration) | Pod (affinity rules referencing node labels) |
| Direction | Node repels pods | Pod selects nodes |
| Enforces exclusivity | Yes — non-tolerating pods cannot land | No — other pods can still use the node |
| Eviction | Yes (NoExecute) | No |
| Best for | Dedicated/reserved nodes | Pod placement preferences |

**Use both together** for truly dedicated nodes:
- Taint the node (`NoSchedule`) — prevents non-tolerating pods
- Add node affinity to the pod (`requiredDuringScheduling`) — ensures it only goes to the right nodes

Tolerations alone don't guarantee placement on the tainted node; they only allow it.

---

## Useful Commands

```bash
# Add a taint
kubectl taint nodes node1 dedicated=database:NoSchedule

# Remove a taint (note the trailing -)
kubectl taint nodes node1 dedicated=database:NoSchedule-

# View taints on a node
kubectl describe node node1 | grep -A 5 Taints

# View all node taints across the cluster
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Check if a pod would be scheduled given taints
kubectl describe pod <pod> | grep -A 5 Tolerations
```
