# Kubernetes Storage: Complete Reference

## Storage Concepts Overview

Kubernetes storage separates the concerns of provisioning storage (an infrastructure concern) from consuming storage (a developer concern). The abstractions are:

```
StorageClass  ──(defines provisioner + parameters)──►  HOW storage is created
PersistentVolume (PV)  ──(represents actual storage)──►  WHAT storage exists
PersistentVolumeClaim (PVC)  ──(requests storage)──►  WHAT a pod needs
Pod  ──(mounts PVC as a volume)──►  WHO uses the storage
```

---

## StorageClass — Dynamic Provisioning

A StorageClass tells Kubernetes how to dynamically provision a PersistentVolume when a PVC is created. Instead of pre-creating PVs manually (static provisioning), you define a StorageClass once, and Kubernetes automatically creates PVs on demand by calling the specified provisioner.

### Key Fields

```yaml
provisioner: kubernetes.io/aws-ebs   # The CSI driver or built-in provisioner
parameters:                          # Provisioner-specific parameters
  type: gp3
  iopsPerGB: "10"
reclaimPolicy: Delete                # What to do with the PV when the PVC is deleted
volumeBindingMode: WaitForFirstConsumer  # When to bind the PV to the PVC
allowVolumeExpansion: true           # Allow PVCs to be resized after creation
mountOptions:                        # Options passed to the mount command
  - debug
```

### Common Cloud StorageClasses

**AWS EBS (gp3 — recommended over gp2):**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

**GCP Persistent Disk (pd-ssd):**
```yaml
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
  replication-type: none
```

**Azure Disk:**
```yaml
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
```

---

## PersistentVolume (PV) — Static Provisioning

A PersistentVolume is a cluster-scoped resource representing a piece of storage. It is either:
- **Statically provisioned**: Created manually by a cluster administrator.
- **Dynamically provisioned**: Created automatically by a StorageClass provisioner when a PVC is bound.

PVs have a lifecycle independent of any pod. When a pod is deleted, the PV persists (unless the reclaim policy deletes it).

### PV Phases
1. `Available` — PV exists and is not bound to any PVC.
2. `Bound` — PV is bound to a specific PVC (one-to-one relationship).
3. `Released` — The PVC was deleted, but the PV has not yet been reclaimed.
4. `Failed` — Automatic reclamation has failed.

---

## PersistentVolumeClaim (PVC) — Requesting Storage

A PVC is a namespace-scoped request for storage. It specifies the storage class, access mode, and capacity required. The PV controller matches the PVC to an available PV (or triggers dynamic provisioning) based on these constraints.

**Binding is permanent:** Once a PVC is bound to a PV, that binding is exclusive for the lifetime of the PVC. The same PV cannot be used by another PVC even if the first PVC has no active pods.

---

## VolumeClaimTemplates (StatefulSets)

For StatefulSets, each pod replica needs its own independent PVC (a database pod must not share storage with its replicas). `volumeClaimTemplates` in a StatefulSet automatically creates a PVC for each pod replica:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ebs-gp3
      resources:
        requests:
          storage: 20Gi
```

This creates PVCs named `data-<statefulset-name>-0`, `data-<statefulset-name>-1`, etc. These PVCs are NOT deleted when the StatefulSet is scaled down or deleted — this is intentional to prevent accidental data loss. You must delete the PVCs manually.

---

## Access Modes

Access modes define how a PV can be mounted. A PV supports one or more access modes, but can only be mounted in one mode at a time.

| Mode | Short | Description | Typical Storage Types |
|---|---|---|---|
| `ReadWriteOnce` | RWO | Read-write by a single node | EBS, Azure Disk, local storage |
| `ReadOnlyMany` | ROX | Read-only by multiple nodes simultaneously | NFS, CephFS |
| `ReadWriteMany` | RWX | Read-write by multiple nodes simultaneously | NFS, CephFS, EFS (via CSI) |
| `ReadWriteOncePod` | RWOP | Read-write by a single **pod** (1.22+, GA in 1.29) | EBS (with CSI driver 1.22+) |

**ReadWriteOncePod** is the most restrictive mode and the recommended default for single-pod workloads. Unlike RWO (which allows multiple pods on the same node to access the volume), RWOP guarantees that only one pod in the entire cluster mounts the volume read-write. This prevents data corruption from concurrent writes.

---

## Reclaim Policies

The reclaim policy controls what happens to the PV when the bound PVC is deleted.

### Retain
The PV is not deleted. Its data is preserved. The PV transitions to `Released` state and must be manually reclaimed by an administrator before it can be reused. Use for:
- Any production data you cannot afford to lose.
- Data that needs to be migrated or exported before deletion.
- Compliance scenarios requiring data retention.

```bash
# To reuse a Released PV manually:
# 1. Delete the PV
# 2. Manually clean up the underlying storage
# 3. Recreate the PV (or let the StorageClass create a new one)
```

### Delete (Default for dynamic provisioning)
The underlying storage resource (EBS volume, GCP disk, etc.) is deleted when the PVC is deleted. Use for:
- Ephemeral scratch space.
- Caches that can be rebuilt.
- Development environments.

**WARNING:** If you accidentally delete a PVC with `reclaimPolicy: Delete`, the data is gone immediately and permanently. In production, use `Retain` for anything that matters.

### Recycle (Deprecated — do not use)
Scrubs the volume with `rm -rf` and makes it available again. Deprecated in Kubernetes 1.11 in favor of dynamic provisioning. Not supported by most CSI drivers.

---

## Volume Types

### hostPath (Development Only)
Mounts a file or directory from the host node's filesystem. Used for:
- Local development and testing (minikube, kind).
- Reading node-level data (e.g., `/var/log` for log collectors).
- DaemonSet workloads that need host filesystem access.

**NEVER use hostPath for application data in production:**
- Data is node-local — if the pod is rescheduled to a different node, it loses access to its data.
- Grants pods access to the host filesystem, which is a significant security risk.
- No replication, no redundancy, no high availability.

### NFS (Network File System)
Mounts an NFS export. Supports ReadWriteMany (RWX), making it suitable for workloads that need shared storage across multiple pods. Requires an NFS server (can be in-cluster using the NFS CSI driver or external). Performance is network-dependent.

### Cloud Volumes
- **AWS EBS** (`ebs.csi.aws.com`): Block storage, ReadWriteOnce. Fast, reliable. Each pod gets its own volume. Not shareable.
- **AWS EFS** (`efs.csi.aws.com`): NFS-based, ReadWriteMany. For shared storage across pods/nodes.
- **GCP Persistent Disk** (`pd.csi.storage.gke.io`): Block storage, ReadWriteOnce.
- **GCP Filestore** (`filestore.csi.storage.gke.io`): NFS, ReadWriteMany.
- **Azure Disk** (`disk.csi.azure.com`): Block storage, ReadWriteOnce.
- **Azure Files** (`file.csi.azure.com`): SMB/NFS, ReadWriteMany.

### ConfigMap and Secret Volumes
Mount ConfigMap or Secret data as files in a pod. Kubernetes updates the mounted files when the ConfigMap/Secret changes (with a short propagation delay). Use for configuration files, certificates, and credentials.

---

## CSI Drivers

The Container Storage Interface (CSI) is the standard API for storage vendors to write Kubernetes storage drivers without modifying the core Kubernetes codebase. CSI replaced the legacy in-tree volume plugins (which are being removed in Kubernetes 1.28+).

**Installing a CSI driver (example: AWS EBS CSI):**
```bash
# Via Helm (recommended):
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system

# The driver deploys:
# - Controller plugin (Deployment): handles volume creation/deletion/attachment
# - Node plugin (DaemonSet): handles volume mounting on each node
```

**Verify CSI driver is installed:**
```bash
kubectl get csidrivers
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

---

## Debugging Storage Issues

```bash
# Check PVC status — is it Bound?
kubectl get pvc -n workloads
# If STATUS is Pending, check Events with describe

# Describe the PVC to see why it's not binding
kubectl describe pvc app-data-claim -n workloads
# Common causes of Pending:
# - No PV matches the access mode, size, or StorageClass
# - WaitForFirstConsumer: PVC stays Pending until a pod is scheduled
# - StorageClass provisioner pod is not running

# Describe the PV to check its status and any error events
kubectl get pv
kubectl describe pv local-pv-1

# Check if the StorageClass exists
kubectl get storageclass

# Check if the CSI driver is running (for dynamic provisioning)
kubectl get pods -n kube-system | grep csi

# Check events in the namespace for storage errors
kubectl get events -n workloads --sort-by='.lastTimestamp' | grep -i volume

# Check the pod is actually mounting the volume
kubectl describe pod <pod-name> -n workloads
# Look at the "Volumes" and "Mounts" sections
# Look at Events for mount failures
```

---

## Related Files

- `storageclass-local.yml` — StorageClass for local development (no-provisioner)
- `persistent-volume.yml` — Static PV using hostPath (dev only)
- `persistent-volume-claim.yml` — PVC requesting storage from the local StorageClass
- `pod-with-pvc.yml` — Pod that mounts the PVC
- `limitrange.yml` — LimitRange enforcing resource defaults and maximums per namespace
