# AKS Setup Guide

This guide walks you through creating a production-grade Azure Kubernetes Service (AKS) cluster and deploying the kube-platform manifests.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Azure CLI (`az`) | >= 2.57.0 | [Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| kubectl | >= 1.32 | `az aks install-cli` |
| Helm | >= 3.14 | [Install guide](https://helm.sh/docs/intro/install/) |

### 1. Authenticate and configure az CLI

```bash
# Log in to Azure
az login

# Set your subscription
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Verify
az account show
```

### 2. Set environment variables

```bash
export SUBSCRIPTION_ID="your-subscription-id"
export RESOURCE_GROUP="kube-platform-rg"
export LOCATION="eastus"
export CLUSTER_NAME="kube-platform"
export KUBERNETES_VERSION="1.32"
export NODE_COUNT=3
export NODE_VM_SIZE="Standard_D4s_v5"
```

---

## Create a Resource Group

```bash
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}"
```

---

## Create the AKS Cluster

```bash
az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --location "${LOCATION}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --node-count "${NODE_COUNT}" \
  --min-count 1 \
  --max-count 10 \
  --enable-cluster-autoscaler \
  --node-vm-size "${NODE_VM_SIZE}" \
  --network-plugin azure \
  --network-policy azure \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-addons monitoring \
  --workspace-resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/kube-platform-logs" \
  --generate-ssh-keys \
  --zones 1 2 3 \
  --uptime-sla
```

### Key flag explanations

| Flag | Purpose |
|------|---------|
| `--enable-cluster-autoscaler` | Scales node pool based on pending Pods |
| `--network-plugin azure` | Azure CNI networking (required for advanced network policies) |
| `--network-policy azure` | Enforce Kubernetes NetworkPolicy using Azure NPM |
| `--enable-managed-identity` | System-assigned managed identity for the cluster (no credentials needed) |
| `--enable-oidc-issuer` | Required for Azure Workload Identity |
| `--enable-workload-identity` | Enables Azure Workload Identity (preferred over pod-managed identity) |
| `--zones 1 2 3` | Spread nodes across 3 availability zones for HA |
| `--uptime-sla` | 99.95% SLA (recommended for production) |

---

## Configure kubectl

```bash
# Download credentials and merge into ~/.kube/config
az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --overwrite-existing

# Verify connectivity
kubectl get nodes
kubectl cluster-info
```

---

## Azure Workload Identity Setup

Azure Workload Identity lets Kubernetes workloads authenticate to Azure services without storing credentials in Pods or Secrets. It replaces the older pod-managed identity (AAD Pod Identity) approach.

```bash
# Get the OIDC issuer URL
OIDC_ISSUER=$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --query "oidcIssuerProfile.issuerUrl" \
  --output tsv)

# 1. Create an Azure Managed Identity
az identity create \
  --name kube-platform-identity \
  --resource-group "${RESOURCE_GROUP}"

CLIENT_ID=$(az identity show \
  --name kube-platform-identity \
  --resource-group "${RESOURCE_GROUP}" \
  --query clientId \
  --output tsv)

# 2. Grant the identity permissions it needs
#    (adjust roles based on what your workload accesses)
az role assignment create \
  --assignee "${CLIENT_ID}" \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

# 3. Create the federated credential (links K8s SA → Azure identity)
az identity federated-credential create \
  --name kube-platform-federated \
  --identity-name kube-platform-identity \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${OIDC_ISSUER}" \
  --subject "system:serviceaccount:NAMESPACE:KUBERNETES_SA_NAME" \
  --audiences api://AzureADTokenExchange

# 4. Annotate the Kubernetes ServiceAccount
kubectl annotate serviceaccount KUBERNETES_SA_NAME \
  --namespace=NAMESPACE \
  "azure.workload.identity/client-id=${CLIENT_ID}"
```

Your Pod spec must also include the label `azure.workload.identity/use: "true"`.

---

## Enable Addons

### Azure Monitor / Container Insights

```bash
# Create Log Analytics Workspace (if not already done)
az monitor log-analytics workspace create \
  --resource-group "${RESOURCE_GROUP}" \
  --workspace-name kube-platform-logs \
  --location "${LOCATION}"

WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "${RESOURCE_GROUP}" \
  --workspace-name kube-platform-logs \
  --query id --output tsv)

# Enable monitoring addon
az aks enable-addons \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --addons monitoring \
  --workspace-resource-id "${WORKSPACE_ID}"
```

### Application Gateway Ingress Controller (AGIC)

```bash
# Create a public IP for the Application Gateway
az network public-ip create \
  --resource-group "${RESOURCE_GROUP}" \
  --name kube-platform-agw-ip \
  --sku Standard

# Enable the ingress-appgw addon
az aks enable-addons \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --addons ingress-appgw \
  --appgw-name kube-platform-agw \
  --appgw-subnet-cidr "10.225.0.0/16"
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
# List all AKS clusters in the subscription
az aks list --output table

# Scale the node pool
az aks scale \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --node-count 5 \
  --nodepool-name nodepool1

# Upgrade the cluster to a new Kubernetes version
az aks upgrade \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --yes

# Stop the cluster (saves compute costs, keeps configuration)
az aks stop \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}"

# Start the cluster
az aks start \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}"

# Delete the cluster (DESTRUCTIVE)
az aks delete \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --yes

# Delete the resource group (deletes ALL resources including the cluster)
az group delete \
  --name "${RESOURCE_GROUP}" \
  --yes
```

---

## Cost Optimization Tips

- Use **Spot node pools** for batch or fault-tolerant workloads.
- Enable **Vertical Pod Autoscaler** to right-size resource requests.
- Use **Azure Reserved Instances** for predictable baseline nodes.
- Set **auto-stop schedules** for dev/staging clusters.
- Enable **Cost Analysis** in the Azure portal to track per-namespace spend.
