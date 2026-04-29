# Kubernetes Storage Guide: CSI Drivers and StorageClass Selection

A practical guide to Kubernetes storage — from core concepts to production StorageClass selection for cloud and on-premises environments. References to repository manifests are provided throughout.

---

## Table of Contents

1. [Storage Concepts Recap](#1-storage-concepts-recap)
2. [Access Modes](#2-access-modes)
3. [Reclaim Policies](#3-reclaim-policies)
4. [Volume Binding Modes](#4-volume-binding-modes)
5. [CSI Driver Comparison](#5-csi-driver-comparison)
6. [StorageClass Selection Decision Tree](#6-storageclass-selection-decision-tree)
7. [Repository References](#7-repository-references)

---

## 1. Storage Concepts Recap

### PersistentVolume (PV)

A PersistentVolume is a piece of storage in the cluster that has been provisioned by an administrator or dynamically by a StorageClass. A PV exists independently of any pod — deleting the pod does not delete the PV. PVs are cluster-scoped (not namespaced). See `core/storage/persistent-volume.yml`.

```
Cluster
  └── PersistentVolume (cluster-scoped)
        ├── capacity: 50Gi
        ├── accessModes: [ReadWriteOnce]
        ├── persistentVolumeReclaimPolicy: Retain
        └── csi:
              driver: ebs.csi.aws.com
              volumeHandle: vol-0abc123
```

### PersistentVolumeClaim (PVC)

A PVC is a request for storage by a user or workload. It specifies the desired access mode, storage class, and minimum capacity. Kubernetes binds a PVC to a matching PV (static) or creates a new PV via the StorageClass (dynamic). See `core/storage/persistent-volume-claim.yml`.

### StorageClass

A StorageClass describes a "tier" of storage and delegates PV provisioning to a CSI driver. Key fields: `provisioner` (CSI driver name), `parameters` (driver-specific), `reclaimPolicy`, `volumeBindingMode`, `allowVolumeExpansion`. See `core/storage/storageclass-local.yml`.

### CSI Driver

The Container Storage Interface is a standardized plugin API that decouples storage provider implementations from core Kubernetes code. A CSI driver consists of:

- **Controller plugin**: runs as a Deployment; handles volume creation, deletion, attachment, snapshots
- **Node plugin**: runs as a DaemonSet; handles volume mounting on the node where the pod is scheduled

The kubelet communicates with the node plugin via a Unix socket to mount/unmount volumes.

---

## 2. Access Modes

Access modes define how many nodes can mount a volume and with what permissions. The StorageClass / CSI driver must support the requested mode — requesting an unsupported mode causes the PVC to stay `Pending`.

| Mode | Abbreviation | Description |
|------|-------------|-------------|
| ReadWriteOnce | RWO | Can be mounted read-write by a single node. Multiple pods on the same node can access it. |
| ReadOnlyMany | ROX | Can be mounted read-only by many nodes simultaneously. |
| ReadWriteMany | RWX | Can be mounted read-write by many nodes simultaneously. |
| ReadWriteOncePod | RWOP | Can be mounted read-write by a single pod (GA in 1.29). Stricter than RWO. |

### When to Use Each Mode

**RWO** is the most common mode and is appropriate for:
- Databases (MySQL, PostgreSQL, MongoDB) — one writer at a time
- Stateful application data that must not be concurrently written from multiple hosts
- Any block storage device (disk can only be attached to one node at a time)

**ROX** is used for:
- Pre-populated read-only data volumes (e.g., model weights, reference datasets)
- Sharing a fixed dataset across many reader pods

**RWX** is required for:
- Shared file systems accessed by multiple pods on different nodes simultaneously
- Web server document roots that multiple replicas must read and write
- Collaborative workloads (ETL jobs writing to shared scratch space)

**RWOP** (ReadWriteOncePod) is used for:
- Strict single-pod ownership guarantees — prevents two pods from mounting the same PVC even on the same node
- Useful for stateful workloads where dual-write would cause data corruption

### Cloud Provider Support Matrix

| Provider | RWO | ROX | RWX | RWOP |
|----------|-----|-----|-----|------|
| AWS EBS (gp3, io2) | Yes | No | No | Yes (1.29+) |
| AWS EFS (via NFS) | Yes | Yes | Yes | No |
| GCP Persistent Disk | Yes | Yes | No | Yes (1.29+) |
| GCP Filestore | Yes | Yes | Yes | No |
| Azure Disk | Yes | No | No | Yes (1.29+) |
| Azure Files (SMB/NFS) | Yes | Yes | Yes | No |
| NFS | Yes | Yes | Yes | No |
| Ceph RBD | Yes | Yes | No | No |
| CephFS | Yes | Yes | Yes | No |
| OpenEBS Jiva | Yes | No | No | No |
| OpenEBS cStor | Yes | No | No | No |
| local (hostPath/direct) | Yes | No | No | No |

---

## 3. Reclaim Policies

The reclaim policy determines what happens to a PV when the bound PVC is deleted.

### Retain

The PV is not deleted. Its status moves to `Released` but it is not available for rebinding until an administrator manually reclaims it (deletes the PV object after archiving the data, or patches its `claimRef`).

**Production recommendation**: Use `Retain` for all stateful, production data. Data is never automatically deleted. Operators must consciously decide to delete the underlying storage.

```yaml
persistentVolumeReclaimPolicy: Retain
```

### Delete

The PV and the underlying storage asset (EBS volume, GCP PD, etc.) are automatically deleted when the PVC is deleted.

**Use case**: Development/staging environments where data is ephemeral and you want automatic cleanup. Also appropriate for ephemeral scratch volumes.

**Caution**: Accidentally deleting a PVC in a production cluster with `Delete` policy causes irreversible data loss.

```yaml
persistentVolumeReclaimPolicy: Delete
```

### Recycle (Deprecated)

Performs a basic `rm -rf /volume/*` on the volume and makes it available for rebinding. Deprecated in favor of dynamic provisioning. Do not use in new deployments.

### Policy Decision Table

| Environment | Recommended Policy | Rationale |
|-------------|-------------------|-----------|
| Production stateful data | `Retain` | Prevents accidental data loss |
| Production ephemeral scratch | `Delete` | Automatic cleanup reduces cost |
| Development/CI | `Delete` | Short lifecycle; cleanup is desirable |
| DR / backup volumes | `Retain` | Must not be auto-deleted |

---

## 4. Volume Binding Modes

The volume binding mode controls when a PV is bound to a PVC.

### Immediate

PV provisioning and binding happen as soon as the PVC is created, regardless of whether any pod has been scheduled. This is the default for cloud block storage StorageClasses that don't have topology constraints.

**Problem with Immediate for zonal storage**: If a PVC is provisioned in zone `us-east-1a` but the pod schedules on a node in `us-east-1b`, the pod will fail to start because the volume is in the wrong zone.

**Use Immediate when**:
- Storage is topology-agnostic (NFS, Ceph, AWS EFS)
- Your cluster is single-zone

### WaitForFirstConsumer

PV provisioning is deferred until a pod that references the PVC is scheduled. At scheduling time, the scheduler knows which node (and therefore which zone) the pod will land on and passes this information to the provisioner, ensuring the volume is created in the correct zone.

**Required when**:
- Using zonal block storage (AWS EBS, GCP PD zonal, Azure Disk)
- Using local/hostPath storage
- Using any topology-constrained storage

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-us-east-1
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # essential for EBS
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```

**Behavior**: PVC shows as `Pending` until a pod is scheduled that references it. This is expected and correct.

---

## 5. CSI Driver Comparison

### Feature Matrix

| CSI Driver | Access Modes | Snapshots | Online Resize | Topology | Notes |
|-----------|-------------|-----------|--------------|---------|-------|
| **AWS EBS CSI** | RWO, RWOP | Yes | Yes (gp3/io2) | Zonal | Default for EKS; use WaitForFirstConsumer |
| **AWS EFS CSI** | RWO, ROX, RWX | No | N/A (elastic) | Regional | NFS-based; no snapshot support natively |
| **GCP PD CSI** | RWO, ROX, RWOP | Yes | Yes | Zonal | Supports pd-ssd, pd-balanced, pd-extreme |
| **GCP Filestore CSI** | RWO, ROX, RWX | Yes | Yes | Regional | NFS; high performance tier available |
| **Azure Disk CSI** | RWO, RWOP | Yes | Yes | Zonal | Premium SSD recommended for production |
| **Azure File CSI** | RWO, ROX, RWX | No | Yes | Regional | SMB or NFS protocol; requires storage account |
| **NFS (external-provisioner)** | RWO, ROX, RWX | No | No | None | Simple; no built-in HA |
| **Ceph RBD** | RWO, ROX | Yes | Yes | Configurable | High performance block storage; requires Ceph cluster |
| **CephFS** | RWO, ROX, RWX | Yes | Yes | Configurable | Shared filesystem; requires Ceph cluster |
| **OpenEBS (LocalPV)** | RWO | No | No | Node-local | Highest IOPS/throughput; no replication |
| **OpenEBS (Jiva/cStor)** | RWO | Yes | Yes | Node-aware | Replicated storage; lower performance than LocalPV |
| **local-static-provisioner** | RWO | No | No | Node-local | Uses local disks; requires pre-configured nodes |

### Key Driver Notes

**AWS EBS CSI (`ebs.csi.aws.com`)**
- gp3 is the recommended volume type: configurable IOPS (up to 16,000) and throughput (up to 1,000 MB/s) independent of size
- io2 Block Express for latency-critical databases requiring up to 256,000 IOPS
- Always use `WaitForFirstConsumer` binding mode
- EBS volumes are limited to one attachment at a time (RWO only)

**GCP Persistent Disk CSI (`pd.csi.storage.gke.io`)**
- `pd-ssd` for production databases, `pd-balanced` for general workloads
- `pd-extreme` (available in select regions) for ultra-high IOPS
- Regional PD (replicated across two zones) is possible but has lower IOPS

**Azure Disk CSI (`disk.csi.azure.com`)**
- `Premium_LRS` (SSD) for production, `Standard_HDD_LRS` for archives
- Ultra Disk for 160,000 IOPS; requires specific VM SKUs
- Ultra Disk and Premium SSD v2 support online resize without detach

**Ceph RBD and CephFS**
- Requires a running Ceph cluster (Rook-Ceph is the standard Kubernetes operator)
- RBD (block) for databases; CephFS (filesystem) for shared access
- Supports VolumeSnapshots, cloning, and resize
- Performance depends on Ceph cluster sizing and network bandwidth

**local-static-provisioner**
- Provisions PVs from locally attached disks (NVMe, SSDs)
- Highest possible IOPS/throughput — no network overhead
- No replication — node failure means data loss unless the application handles replication (e.g., Cassandra, Kafka)
- Requires pre-formatting and mounting disks on nodes before provisioning

---

## 6. StorageClass Selection Decision Tree

Use this tree to select the appropriate StorageClass for a workload:

```
Start
  │
  ├─► Is the cluster on a public cloud?
  │     │
  │     ├─► AWS?
  │     │     ├─► Need RWX (shared)? → AWS EFS CSI (RWX, no snapshots)
  │     │     └─► Single-writer (DB, stateful app)?
  │     │           ├─► Need high IOPS (>16k)? → EBS io2 (WaitForFirstConsumer, Retain)
  │     │           └─► General purpose? → EBS gp3 (WaitForFirstConsumer, Retain)
  │     │
  │     ├─► GCP?
  │     │     ├─► Need RWX? → Filestore CSI
  │     │     └─► Single-writer?
  │     │           ├─► High IOPS? → pd-ssd or pd-extreme
  │     │           └─► General? → pd-balanced (WaitForFirstConsumer)
  │     │
  │     └─► Azure?
  │           ├─► Need RWX? → Azure Files CSI (NFS mode)
  │           └─► Single-writer?
  │                 ├─► High IOPS? → Azure Ultra Disk or Premium SSD v2
  │                 └─► General? → Azure Disk Premium_LRS
  │
  └─► On-premises / bare-metal?
        │
        ├─► Have a Ceph cluster (Rook)?
        │     ├─► Need RWX? → CephFS StorageClass
        │     └─► Block? → Ceph RBD StorageClass
        │
        ├─► Need maximum local IOPS (no replication at storage layer)?
        │     └─► local-static-provisioner (node-local, no HA)
        │
        ├─► Simple shared storage with an NFS server?
        │     └─► NFS external-provisioner
        │
        └─► Need replicated storage without Ceph?
              └─► OpenEBS cStor or Longhorn
```

### Reclaim Policy Quick Reference

- **Production stateful data** → always `Retain`
- **Ephemeral / development** → `Delete` is acceptable
- **CI/CD scratch volumes** → `Delete` for automatic cleanup

### Binding Mode Quick Reference

- **Cloud block storage (EBS, GCP PD, Azure Disk)** → `WaitForFirstConsumer`
- **Shared/distributed storage (EFS, NFS, CephFS)** → `Immediate`
- **Local storage** → `WaitForFirstConsumer`

---

## 7. Repository References

| File | Description |
|------|-------------|
| `core/storage/persistent-volume.yml` | Example static PV definition |
| `core/storage/persistent-volume-claim.yml` | Example PVC definition |
| `core/storage/storageclass-local.yml` | Local path StorageClass example |
| `core/storage/limitrange.yml` | LimitRange defaults for the namespace |
| `core/storage/pod-with-pvc.yml` | Example pod consuming a PVC |
| `core/workloads/statefulset/` | StatefulSet with volumeClaimTemplate |

### Example StorageClass with Best-Practice Settings

```yaml
# Production EBS StorageClass (AWS)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3-retain
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:us-east-1:123456789:key/mrk-abc123
```

### VolumeSnapshot Example

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: mysql-snapshot-2026-04-29
  namespace: production
spec:
  volumeSnapshotClassName: ebs-vsc
  source:
    persistentVolumeClaimName: mysql-data
```

Snapshots require a `VolumeSnapshotClass` backed by a CSI driver that supports the `CREATE_DELETE_SNAPSHOT` capability. Verify with:
```bash
kubectl get volumesnapshotclass
kubectl get volumesnapshot -n <namespace>
kubectl describe volumesnapshot <name> -n <namespace>
```
