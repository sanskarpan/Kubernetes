# Velero — Kubernetes Backup and Restore

[Velero](https://velero.io/) provides disaster recovery, cluster migration, and data protection for Kubernetes workloads and persistent volumes.

---

## Architecture

```
Kubernetes Cluster
    |
    v
[ Velero Server (Pod) ]
    |                 \
    v                  v
[ Object Storage ]  [ Volume Snapshots ]
  (S3/GCS/Azure)    (EBS/PD/Azure Disk)
```

Velero consists of:
- **Velero server**: runs in the cluster, manages backup/restore operations
- **BackupStorageLocation (BSL)**: where backup metadata is stored (S3, GCS, Azure Blob)
- **VolumeSnapshotLocation (VSL)**: where volume snapshots are stored (cloud provider)

---

## Prerequisites

- Kubernetes >= 1.25
- Helm >= 3.14
- Object storage bucket (S3, GCS, or Azure Blob)
- Appropriate IAM permissions for Velero to access object storage

---

## Installation

### 1. Install the Velero CLI

```bash
# macOS
brew install velero

# Linux (amd64)
VELERO_VERSION="1.14.0"
curl -fsSL "https://github.com/vmware-tanzu/velero/releases/download/v${VELERO_VERSION}/velero-v${VELERO_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /tmp
sudo mv "/tmp/velero-v${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/velero

# Verify
velero version --client-only
```

### 2. Install Velero with Helm

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --version 7.2.1 \
  --set-json "configuration.backupStorageLocation[0].name=default" \
  --set-json "configuration.backupStorageLocation[0].provider=aws" \
  --set-json "configuration.backupStorageLocation[0].bucket=your-velero-bucket" \
  --set-json "configuration.backupStorageLocation[0].config.region=us-east-1" \
  --set serviceAccount.server.annotations."eks.amazonaws.com/role-arn"="arn:aws:iam::ACCOUNT_ID:role/velero-role"

# Verify
kubectl get pods -n velero
velero backup-location get
```

---

## BackupStorageLocation Configuration

### AWS S3

```bash
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set-json 'configuration.backupStorageLocation[0]={"name":"default","provider":"aws","bucket":"your-bucket","config":{"region":"us-east-1"}}' \
  --set-json 'configuration.volumeSnapshotLocation[0]={"name":"default","provider":"aws","config":{"region":"us-east-1"}}' \
  --set credentials.useSecret=false \
  --set serviceAccount.server.annotations."eks.amazonaws.com/role-arn"="arn:aws:iam::ACCOUNT_ID:role/velero-role"
```

### Google Cloud Storage (GCS)

```bash
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set-json 'configuration.backupStorageLocation[0]={"name":"default","provider":"gcp","bucket":"your-gcs-bucket","config":{}}' \
  --set-json 'configuration.volumeSnapshotLocation[0]={"name":"default","provider":"gcp","config":{"project":"your-project-id"}}' \
  --set credentials.useSecret=false \
  --set serviceAccount.server.annotations."iam.gke.io/gcp-service-account"="velero@your-project.iam.gserviceaccount.com"
```

### Azure Blob Storage

```bash
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set-json 'configuration.backupStorageLocation[0]={"name":"default","provider":"azure","bucket":"your-container","config":{"resourceGroup":"velero-rg","storageAccount":"velerosa"}}' \
  --set-json 'configuration.volumeSnapshotLocation[0]={"name":"default","provider":"azure","config":{"resourceGroup":"velero-rg"}}' \
  --set credentials.useSecret=false \
  --set serviceAccount.server.annotations."azure.workload.identity/client-id"="your-client-id"
```

---

## Apply the Backup Schedule

```bash
# Apply the daily backup schedule
kubectl apply -f platform/storage/velero/backup-schedule.yml

# Verify the schedule is registered
velero schedule get

# Trigger a manual backup from the schedule immediately (for testing)
velero backup create manual-test --from-schedule=daily-statefulset-backup

# Watch the backup progress
velero backup describe manual-test --details
```

---

## Restore from Backup

```bash
# List available backups
velero backup get

# Edit restore-example.yml to set the correct backupName, then apply:
kubectl apply -f platform/storage/velero/restore-example.yml

# Monitor restore progress
kubectl get restore -n velero --watch
velero restore describe restore-data-namespace --details

# Or restore directly via CLI:
velero restore create \
  --from-backup daily-statefulset-backup-20260115020000 \
  --include-namespaces data \
  --restore-volumes
```

---

## Useful Commands

```bash
# List all backups
velero backup get

# Describe a backup (shows included resources, errors, warnings)
velero backup describe <backup-name> --details

# Download backup logs
velero backup logs <backup-name>

# Delete a backup
velero backup delete <backup-name>

# List all restores
velero restore get

# Describe a restore
velero restore describe <restore-name> --details

# Uninstall Velero
helm uninstall velero -n velero
kubectl delete namespace velero
```

---

## Monitoring

Velero exposes Prometheus metrics on port 8085. Add the following ServiceMonitor if using kube-prometheus-stack:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: velero
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames: [velero]
  selector:
    matchLabels:
      app.kubernetes.io/name: velero
  endpoints:
    - port: monitoring
      interval: 30s
```

Key metrics to alert on:
- `velero_backup_failure_total` — number of failed backups
- `velero_backup_last_status` — 1 = success, 0 = failure
- `velero_restore_failure_total` — number of failed restores
