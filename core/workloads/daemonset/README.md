# DaemonSets — Deep Dive

## What Is a DaemonSet?

A DaemonSet ensures that **exactly one copy of a pod runs on every node** in the cluster (or a subset of nodes matched by a nodeSelector/affinity). When a new node joins the cluster, the DaemonSet controller automatically schedules the pod on it. When a node is removed, the pod is garbage collected.

This is fundamentally different from a Deployment, which schedules a fixed number of replicas across any available nodes without caring which nodes get pods.

---

## How It Works

The DaemonSet controller watches the cluster for node additions and removals. For each node that matches the DaemonSet's `nodeSelector` (or all nodes if no selector is specified):
1. The controller creates a pod bound to that specific node (`spec.nodeName` is set directly).
2. The pod bypasses the normal scheduler priority queue — it is placed by the DaemonSet controller, not the kube-scheduler (though kube-scheduler is used in newer versions with ScheduleDaemonSetPods feature gate).

---

## Use Cases

| Use Case | Example Tools | Why DaemonSet? |
|---|---|---|
| **Log Collection** | Fluentd, Fluent Bit, Filebeat | Must collect logs from every node's `/var/log` directory |
| **Metrics Collection** | node-exporter, cAdvisor | Node-level CPU, memory, disk, network metrics require host access |
| **Network Agents** | Calico, Weave Net, Cilium | CNI plugins must run on every node to manage pod networking |
| **Storage Agents** | Ceph, Longhorn node agent | Distributed storage requires an agent on every storage node |
| **Security Agents** | Falco, Sysdig, Tetragon | Host-level security monitoring needs to run on every node |
| **Service Mesh** | Linkerd, Istio CNI | Proxy injection or CNI setup needed on every node |
| **GPU Drivers** | NVIDIA device plugin | Hardware-specific plugin must run on nodes with GPUs |

---

## DaemonSet vs. Deployment — Decision Criteria

| Criteria | DaemonSet | Deployment |
|---|---|---|
| **One pod per node?** | Yes — guaranteed | No — replicas spread across nodes arbitrarily |
| **Host filesystem access?** | Ideal (`hostPath`) | Possible but discouraged |
| **Scales with cluster?** | Automatically (new node = new pod) | Manual or HPA (CPU/memory metrics) |
| **Fixed replica count?** | No — count = number of nodes | Yes |
| **Node-specific configuration?** | Yes (downward API exposes node name) | No |
| **Need to skip some nodes?** | Use `nodeSelector` or `nodeAffinity` | N/A |

**Decision Rule:** If your workload needs to run on EVERY node (or every node of a specific type), use a DaemonSet. If you need N copies spread across the cluster, use a Deployment.

---

## Tolerations for Control-Plane Nodes

By default, DaemonSet pods do NOT run on control-plane nodes because control-plane nodes have a taint:

```
node-role.kubernetes.io/control-plane:NoSchedule
```

In most clusters, this is correct — you don't want log collectors or network agents competing with etcd and kube-apiserver for resources.

**When to add control-plane tolerations:**
- Network plugins (CNI) — Calico/Cilium MUST run on control-plane nodes to enable pod networking
- Security agents — You want full coverage including control plane
- Node-exporter — For complete cluster metrics visibility

```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
# Also needed for older cluster versions that use master instead of control-plane:
- key: node-role.kubernetes.io/master
  operator: Exists
  effect: NoSchedule
```

> **Interview Callout:** "How do you run a DaemonSet on control-plane nodes?" — Add a toleration for the `node-role.kubernetes.io/control-plane:NoSchedule` taint. Without this toleration, the DaemonSet pod is not scheduled on tainted nodes.

---

## Update Strategies

```yaml
updateStrategy:
  type: RollingUpdate       # Default — updates one node at a time
  rollingUpdate:
    maxUnavailable: 1       # How many pods can be unavailable during update
    maxSurge: 0             # DaemonSets don't support surge (one pod per node)
```

```yaml
updateStrategy:
  type: OnDelete            # Manual control — new pod only created when old pod is deleted
                            # Useful for testing updates on specific nodes before rolling out
```

**RollingUpdate** is the default and appropriate for most cases.
**OnDelete** gives maximum control — you delete the pod on specific nodes manually to trigger the update. Useful during critical rollouts where you want to verify each node before proceeding.

---

## HostPath Security Considerations

DaemonSets frequently need access to the host filesystem (log files, device files). This requires `hostPath` volumes, which are powerful but risky:

- A misconfigured hostPath can give container access to sensitive host files.
- Combined with `privileged: true`, a container can escape to the host.
- Always use the most restrictive hostPath type:
  - `File` — mounts a single file, not a directory
  - `Directory` — mounts a specific directory
  - `Socket` — mounts a Unix socket
- Never use `hostPath: /` or mount sensitive host paths like `/etc`, `/proc`, `/sys` unless absolutely necessary (security agents may legitimately need these).

For log collection (reading `/var/log`), the container needs read access but NOT write. Mount with `readOnly: true`:
```yaml
volumeMounts:
- name: varlog
  mountPath: /var/log/host
  readOnly: true
```

> **Interview Callout:** "What's the security risk of hostPath volumes?" — A container with write access to a sensitive hostPath (like `/var/log`, `/etc`, or `/`) combined with elevated privileges can escape the container boundary and modify host files. Mitigate with `readOnly: true`, specific path types, and minimal Linux capabilities.

---

## Files in This Directory

| File | Purpose |
|---|---|
| `daemonset.yml` | Production DaemonSet with Namespace — log collector example |

## Apply and Verify

```bash
kubectl apply -f daemonset.yml

# Verify one pod per node
kubectl get pods -n logging -o wide

# Should show one pod per node — count matches node count
kubectl get nodes --no-headers | wc -l
kubectl get pods -n logging --no-headers | wc -l

# View logs from the log collector on a specific node
kubectl logs -n logging -l app.kubernetes.io/name=log-collector --prefix
```
