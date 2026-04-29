# GKE Setup Guide

This guide walks you through creating a production-grade Google Kubernetes Engine (GKE) cluster and deploying the kube-platform manifests.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| gcloud CLI | >= 460.0.0 | [Install guide](https://cloud.google.com/sdk/docs/install) |
| kubectl | >= 1.32 | `gcloud components install kubectl` |
| Helm | >= 3.14 | [Install guide](https://helm.sh/docs/intro/install/) |

### 1. Authenticate and configure gcloud

```bash
# Log in to Google Cloud
gcloud auth login

# Set your project
gcloud config set project YOUR_PROJECT_ID

# Enable required APIs
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com

# Verify
gcloud config list
```

### 2. Set environment variables

```bash
export PROJECT_ID="your-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"
export CLUSTER_NAME="kube-platform"
export CLUSTER_VERSION="1.32"
```

---

## Option A: GKE Autopilot (Recommended)

Autopilot is a fully managed GKE mode where Google manages the node pool, scaling, and security. You pay per Pod resource request rather than per node.

**Benefits:**
- No node management (patching, scaling, bin-packing)
- Built-in security hardening (Shielded Nodes, Workload Identity, node auto-provisioning)
- Cost efficiency — pay only for what Pods request

```bash
gcloud container clusters create-auto "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --release-channel="regular" \
  --cluster-version="${CLUSTER_VERSION}" \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --project="${PROJECT_ID}"
```

> Note: Autopilot clusters require all workloads to comply with [Autopilot resource limits](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-resource-requests).

---

## Option B: GKE Standard Cluster

Use Standard mode when you need full control over node configuration, custom taints, or GPU/TPU nodes.

```bash
gcloud container clusters create "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --release-channel="regular" \
  --cluster-version="${CLUSTER_VERSION}" \
  --machine-type="e2-standard-4" \
  --num-nodes=3 \
  --min-nodes=1 \
  --max-nodes=10 \
  --enable-autoscaling \
  --enable-autorepair \
  --enable-autoupgrade \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --enable-ip-alias \
  --network="default" \
  --subnetwork="default" \
  --logging=SYSTEM,WORKLOAD \
  --monitoring=SYSTEM \
  --addons=HttpLoadBalancing,HorizontalPodAutoscaling,GcePersistentDiskCsiDriver
```

### Key flag explanations

| Flag | Purpose |
|------|---------|
| `--release-channel=regular` | Automatic minor version upgrades (stable cadence) |
| `--enable-autoscaling` | Cluster Autoscaler scales nodes based on demand |
| `--workload-pool` | Enables Workload Identity (replaces static service account keys) |
| `--enable-shielded-nodes` | Verified boot, vTPM, and integrity monitoring |
| `--enable-ip-alias` | VPC-native networking (required for many addons) |
| `--addons=GcePersistentDiskCsiDriver` | CSI driver for PersistentVolume support |

---

## Configure kubectl

```bash
# Download credentials and update ~/.kube/config
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

# Verify connectivity
kubectl get nodes
kubectl cluster-info
```

---

## Workload Identity Setup

Workload Identity lets Kubernetes ServiceAccounts impersonate Google Cloud IAM service accounts without static JSON keys. This is the recommended approach for GCP API access from Pods.

```bash
# 1. Create a Google Cloud IAM service account
gcloud iam service-accounts create kube-platform-sa \
  --display-name="kube-platform workload identity SA" \
  --project="${PROJECT_ID}"

# 2. Grant the IAM SA the permissions it needs
#    (adjust roles based on what your workload requires)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:kube-platform-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"

# 3. Allow the Kubernetes SA to impersonate the IAM SA
gcloud iam service-accounts add-iam-policy-binding \
  "kube-platform-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[NAMESPACE/KUBERNETES_SA_NAME]"

# 4. Annotate the Kubernetes ServiceAccount
kubectl annotate serviceaccount KUBERNETES_SA_NAME \
  --namespace=NAMESPACE \
  "iam.gke.io/gcp-service-account=kube-platform-sa@${PROJECT_ID}.iam.gserviceaccount.com"
```

---

## Enable Cluster Addons

### Config Connector (manage GCP resources via Kubernetes CRDs)

```bash
gcloud container clusters update "${CLUSTER_NAME}" \
  --update-addons ConfigConnector=ENABLED \
  --region="${REGION}"
```

### GKE Gateway API (next-gen Ingress)

```bash
# Enable Gateway API CRDs (already available on GKE 1.24+)
gcloud container clusters update "${CLUSTER_NAME}" \
  --gateway-api=standard \
  --region="${REGION}"
```

---

## Apply This Repo's Manifests

```bash
# Clone the repo
git clone https://github.com/sanskarpan/Kubernetes.git
cd Kubernetes

# Apply core manifests
kubectl apply -k core/

# Deploy with Helm
helm install apache ./helm/apache --namespace web --create-namespace
helm install node-app ./helm/node-app --namespace api --create-namespace
helm install mysql ./helm/mysql --namespace data --create-namespace

# Or deploy all with helmfile
helmfile sync
```

---

## Useful Commands

```bash
# List all clusters in the project
gcloud container clusters list --project="${PROJECT_ID}"

# Resize the cluster
gcloud container clusters resize "${CLUSTER_NAME}" \
  --node-pool=default-pool \
  --num-nodes=5 \
  --region="${REGION}"

# Upgrade the cluster to a new Kubernetes version
gcloud container clusters upgrade "${CLUSTER_NAME}" \
  --master \
  --cluster-version="${CLUSTER_VERSION}" \
  --region="${REGION}"

# Delete the cluster (DESTRUCTIVE)
gcloud container clusters delete "${CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"
```

---

## Cost Optimization Tips

- Use **Spot VMs** for non-critical workloads: add `--spot` to node pool creation.
- Enable **Vertical Pod Autoscaler** to right-size resource requests.
- Use **Committed Use Discounts** for predictable baseline workloads.
- Set **resource requests** accurately — Autopilot bills based on requests.
