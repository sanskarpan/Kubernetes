# StatefulSets — Deep Dive

## What Is a StatefulSet?

A StatefulSet is a Kubernetes workload API object designed for **stateful applications** — workloads that require stable, persistent identity and ordered lifecycle management. Unlike Deployments (which treat pods as interchangeable cattle), StatefulSets treat each pod as a named individual with a guaranteed identity that persists across restarts.

---

## Core Properties

### 1. Stable Network Identity

Each pod in a StatefulSet gets a **predictable, stable hostname** derived from the StatefulSet name and its ordinal index:

```
<statefulset-name>-<ordinal>
```

For a StatefulSet named `mysql` with 3 replicas:
- `mysql-0`
- `mysql-1`
- `mysql-2`

These names are **sticky** — if `mysql-1` is deleted and rescheduled, it will come back as `mysql-1`, not `mysql-3`. This is fundamentally different from Deployments where pods get random suffixes like `mysql-7d6f8b9c4-xkqzp`.

**DNS Resolution** (requires a Headless Service — see below):
```
<pod-name>.<headless-service-name>.<namespace>.svc.cluster.local
```

For example:
```
mysql-0.mysql-headless.database.svc.cluster.local
mysql-1.mysql-headless.database.svc.cluster.local
```

This allows pods to discover and communicate with **specific** peers — critical for database replication, leader election, and quorum-based systems.

---

### 2. Ordered Deployment and Scaling

StatefulSets enforce strict **ordering guarantees**:

**Scale Up:** Pods are created sequentially — `pod-0` must be Running and Ready before `pod-1` is created, and so on. This matters for applications like MySQL where the primary (pod-0) must be ready before replicas try to connect to it.

**Scale Down:** Pods are terminated in **reverse ordinal order** — `pod-2` is deleted before `pod-1`, which is deleted before `pod-0`. This protects the primary/leader in most database configurations.

**Updates:** By default (OrderedReady), updates proceed from the highest ordinal down to 0, one at a time.

```
podManagementPolicy: OrderedReady  # default — strict ordering
podManagementPolicy: Parallel      # all pods start/stop simultaneously (use for independent stateful pods)
```

> **Interview Callout:** "What's the difference between `OrderedReady` and `Parallel` pod management?" — `OrderedReady` ensures each pod is healthy before the next starts; `Parallel` sacrifices ordering for speed. Use `Parallel` for stateless-within-stateful scenarios like sharded caches.

---

### 3. VolumeClaimTemplates vs. PVCs

This is the most powerful feature of StatefulSets. A `volumeClaimTemplate` acts as a **PVC factory** — it creates a unique, named PVC for each pod automatically.

**With a Deployment (wrong for databases):**
```yaml
volumes:
- name: mysql-data
  persistentVolumeClaim:
    claimName: mysql-pvc   # ALL pods share the same PVC — data corruption!
```

**With a StatefulSet (correct):**
```yaml
volumeClaimTemplates:
- metadata:
    name: mysql-data
  spec:
    accessModes: ["ReadWriteOncePod"]
    resources:
      requests:
        storage: 10Gi
```

Kubernetes automatically creates PVCs named `<template-name>-<pod-name>`:
- `mysql-data-mysql-0`
- `mysql-data-mysql-1`
- `mysql-data-mysql-2`

Each pod gets its **own isolated storage**. When pod `mysql-1` is rescheduled, it reattaches to `mysql-data-mysql-1` — its data is never lost.

**PVC Retention Policy** (Kubernetes 1.27+):
```yaml
persistentVolumeClaimRetentionPolicy:
  whenDeleted: Retain    # PVCs survive StatefulSet deletion (safe default)
  whenScaledDown: Retain # PVCs survive scale-down (safe default)
```
Setting `whenDeleted: Delete` would destroy data when the StatefulSet is deleted — **never use in production** without understanding this.

---

### 4. Headless Service Requirement

A StatefulSet requires a **Headless Service** to provide stable DNS for individual pod addressing. A headless service has `clusterIP: None`, which tells Kubernetes **not** to provision a virtual IP for the service. Instead, DNS queries for the service return the IP addresses of the individual pods directly.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless
spec:
  clusterIP: None       # This makes it headless
  selector:
    app.kubernetes.io/name: mysql
  ports:
  - port: 3306
```

With this in place, `nslookup mysql-headless.database.svc.cluster.local` returns multiple A records — one per pod. And `nslookup mysql-0.mysql-headless.database.svc.cluster.local` resolves to exactly `mysql-0`'s IP.

> **Interview Callout:** "Why do StatefulSets need a headless service?" — Without `clusterIP: None`, the service would load-balance across pods and you'd lose the ability to address specific pods by DNS. The headless service enables per-pod DNS A records.

The `serviceName` field in the StatefulSet spec **must match** the headless service name:
```yaml
spec:
  serviceName: mysql-headless  # must match the headless service name
```

---

## Common Use Cases

| Use Case | Why StatefulSet? |
|---|---|
| **MySQL / PostgreSQL** | Primary needs stable identity for replica registration; each node needs dedicated storage |
| **Elasticsearch** | Nodes form a cluster using stable DNS; each node has its own index shards |
| **Kafka / RabbitMQ** | Brokers have stable broker IDs; consumer offsets are stored per-broker |
| **ZooKeeper / etcd** | Quorum-based systems require stable member identities for leader election |
| **Redis Sentinel/Cluster** | Sentinel monitors specific masters by hostname; cluster nodes have stable slots |
| **Cassandra** | Peer discovery uses stable seed node addresses |

---

## Update Strategy

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 0   # Only update pods with ordinal >= partition
```

**Canary updates** with StatefulSets: Set `partition: 2` on a 3-replica StatefulSet. Only `mysql-2` (ordinal 2) gets the new version. `mysql-0` and `mysql-1` stay on the old version. Verify `mysql-2` is healthy, then set `partition: 0` to roll out to all.

---

## WARNING: MySQL-as-Deployment Anti-Pattern

**Never run MySQL (or any primary database) as a Deployment.**

Here is why this is dangerous:

1. **Shared or missing PVC:** If all replicas share one PVC (ReadWriteOnce), concurrent writes from multiple pods corrupt the database. If each replica uses an independent PVC created manually, pod rescheduling may attach the wrong PVC.

2. **No stable identity:** MySQL replicas register with the primary using hostname. A Deployment pod's hostname changes on reschedule, breaking replication.

3. **No ordering guarantees:** If a Deployment scales up, replicas may try to connect to a primary that isn't ready yet.

4. **Split-brain risk:** Two pods can be Running simultaneously during a rolling update, both writing to the same data — catastrophic for transactional databases.

The correct answer in every production environment:
- **Single-node MySQL:** Use a StatefulSet with 1 replica (not a Deployment). You get stable identity and a properly managed PVC.
- **Multi-node MySQL:** Use a StatefulSet with an init container or sidecar (like Vitess or the MySQL Operator) to handle replication setup.
- **Even better:** Use the [MySQL Operator for Kubernetes](https://dev.mysql.com/doc/mysql-operator/en/) or a managed database service.

> **Interview Callout:** "Can you run a database in Kubernetes?" — The correct answer is "Yes, but it requires a StatefulSet, not a Deployment, and you must carefully plan storage classes, PVC retention policies, backup strategies, and replication topology. For production, consider a purpose-built operator."

---

## Files in This Directory

| File | Purpose |
|---|---|
| `mysql-namespace.yml` | Namespace with Pod Security Standards enforcement |
| `mysql-configmap.yml` | Non-sensitive MySQL configuration |
| `mysql-secret.yml` | Sensitive credentials (see warning — use SealedSecrets in prod) |
| `mysql-statefulset.yml` | Production-grade 3-replica MySQL StatefulSet |
| `mysql-service-headless.yml` | Headless service for stable pod DNS |
| `mysql-service-clusterip.yml` | Regular ClusterIP service for application connections |

## Apply Order

```bash
kubectl apply -f mysql-namespace.yml
kubectl apply -f mysql-configmap.yml
kubectl apply -f mysql-secret.yml
kubectl apply -f mysql-service-headless.yml   # headless service must exist before StatefulSet
kubectl apply -f mysql-service-clusterip.yml
kubectl apply -f mysql-statefulset.yml
```

## Verify

```bash
# Watch pods come up in order (0, then 1, then 2)
kubectl get pods -n database -w

# Verify each pod has its own PVC
kubectl get pvc -n database

# Test DNS from inside the cluster
kubectl run -it --rm debug --image=busybox --restart=Never -n database -- \
  nslookup mysql-0.mysql-headless.database.svc.cluster.local

# Check StatefulSet status
kubectl rollout status statefulset/mysql -n database
```
