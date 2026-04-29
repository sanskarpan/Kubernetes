# Amazon EKS — Cluster Setup with eksctl

This guide walks you through creating a production-ready Amazon EKS cluster using `eksctl`. EKS is AWS's managed Kubernetes service — AWS runs and manages the control plane; you manage the worker nodes (or use Fargate for serverless nodes).

---

## Prerequisites

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| AWS CLI | 2.x | `brew install awscli` / [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| `eksctl` | 0.200.0 | `brew install eksctl` / [eksctl.io](https://eksctl.io/installation/) |
| `kubectl` | 1.30.0+ | `brew install kubectl` |
| AWS Account | — | With IAM permissions (see below) |

### Required IAM Permissions

Your AWS IAM user or role must have the following permissions (or `AdministratorAccess` for learning):

- `eks:*`
- `ec2:*`
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PutRolePolicy`, `iam:GetRole`, `iam:PassRole`
- `cloudformation:*`
- `autoscaling:*`

For production, scope permissions to the minimum required.

---

## Step 1 — Configure AWS CLI

```bash
# Configure credentials (interactive)
aws configure

# Or use environment variables
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_DEFAULT_REGION="us-east-1"

# Verify
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-username"
}
```

---

## Step 2 — Create the EKS Cluster

### Option A — eksctl command (quick start)

```bash
eksctl create cluster \
  --name kube-platform \
  --region us-east-1 \
  --kubernetes-version 1.32 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 5 \
  --managed \
  --with-oidc \
  --ssh-access \
  --ssh-public-key ~/.ssh/id_rsa.pub
```

This command:
- Creates a VPC with public and private subnets across 3 AZs.
- Creates the EKS control plane (managed by AWS).
- Creates a managed node group with 3 `t3.medium` nodes (auto-scaling 2–5).
- Enables the IAM OIDC provider (required for IAM Roles for Service Accounts — IRSA).
- Takes approximately 15–20 minutes.

### Option B — eksctl cluster config file (recommended for production)

```yaml
# eksctl-cluster.yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: kube-platform
  region: us-east-1
  version: "1.32"

availabilityZones: ["us-east-1a", "us-east-1b", "us-east-1c"]

iam:
  withOIDC: true

managedNodeGroups:
  - name: general-workers
    instanceType: t3.medium
    minSize: 2
    maxSize: 5
    desiredCapacity: 3
    volumeSize: 50
    volumeType: gp3
    amiFamily: AmazonLinux2
    labels:
      node-type: general
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/kube-platform: "owned"
    iam:
      withAddonPolicies:
        autoScaler: true
        albIngress: true
        cloudWatch: true
        ebs: true

  - name: spot-workers
    instanceTypes: ["t3.medium", "t3.large", "t3a.medium"]
    spot: true
    minSize: 0
    maxSize: 10
    desiredCapacity: 0
    volumeSize: 50
    labels:
      node-type: spot

cloudWatch:
  clusterLogging:
    enableTypes:
      - "api"
      - "audit"
      - "authenticator"
      - "controllerManager"
      - "scheduler"
```

Apply:

```bash
eksctl create cluster -f eksctl-cluster.yaml
```

---

## Step 3 — Verify the Cluster

```bash
# Check cluster status
eksctl get cluster --name kube-platform --region us-east-1

# Update kubeconfig
aws eks update-kubeconfig \
  --name kube-platform \
  --region us-east-1

# Verify kubectl context
kubectl config current-context

# Check nodes
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system
```

---

## Step 4 — Node Group Setup

### Add a new node group

```bash
eksctl create nodegroup \
  --cluster kube-platform \
  --name high-memory-workers \
  --node-type r5.large \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed
```

### Scale an existing node group

```bash
eksctl scale nodegroup \
  --cluster kube-platform \
  --name standard-workers \
  --nodes 5

# Or use kubectl
kubectl scale --replicas=5 \
  -n kube-system \
  deployment/cluster-autoscaler
```

### Delete a node group

```bash
eksctl delete nodegroup \
  --cluster kube-platform \
  --name spot-workers \
  --drain
```

---

## Step 5 — IAM OIDC Provider Association

The OIDC provider enables IAM Roles for Service Accounts (IRSA), which is the recommended way to give pods AWS API access without static credentials.

```bash
# Associate OIDC provider (if not done during cluster creation)
eksctl utils associate-iam-oidc-provider \
  --cluster kube-platform \
  --region us-east-1 \
  --approve

# Verify
aws iam list-open-id-connect-providers
```

### Create an IAM Service Account (IRSA example — S3 read access)

```bash
# Create a policy
cat <<EOF > /tmp/s3-read-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-bucket",
        "arn:aws:s3:::my-bucket/*"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name S3ReadPolicy \
  --policy-document file:///tmp/s3-read-policy.json

# Create the IAM service account
eksctl create iamserviceaccount \
  --name s3-reader \
  --namespace my-app \
  --cluster kube-platform \
  --region us-east-1 \
  --attach-policy-arn arn:aws:iam::123456789012:policy/S3ReadPolicy \
  --approve \
  --override-existing-serviceaccounts
```

---

## Step 6 — Connect kubectl

```bash
# Update/add the EKS context to your kubeconfig
aws eks update-kubeconfig \
  --name kube-platform \
  --region us-east-1

# Verify connection
kubectl cluster-info
kubectl get nodes

# If you have multiple clusters, switch context
kubectl config use-context arn:aws:eks:us-east-1:123456789012:cluster/kube-platform
```

---

## Step 7 — Key Add-ons

### EBS CSI Driver (persistent volumes backed by EBS)

```bash
# Create IAM role for the EBS CSI driver
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster kube-platform \
  --region us-east-1 \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

# Install the EBS CSI driver add-on
aws eks create-addon \
  --cluster-name kube-platform \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn arn:aws:iam::123456789012:role/AmazonEKS_EBS_CSI_DriverRole \
  --region us-east-1

# Verify
kubectl get pods -n kube-system -l app=ebs-csi-controller
```

### CoreDNS (usually pre-installed, update to latest)

```bash
aws eks describe-addon \
  --cluster-name kube-platform \
  --addon-name coredns \
  --region us-east-1 \
  --query "addon.addonVersion"

# Update to latest
aws eks update-addon \
  --cluster-name kube-platform \
  --addon-name coredns \
  --resolve-conflicts OVERWRITE \
  --region us-east-1
```

### kube-proxy (usually pre-installed, update to latest)

```bash
aws eks update-addon \
  --cluster-name kube-platform \
  --addon-name kube-proxy \
  --resolve-conflicts OVERWRITE \
  --region us-east-1
```

### AWS Load Balancer Controller (replaces classic ELB integration)

```bash
# Create IAM policy
curl -o /tmp/aws-load-balancer-controller-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/aws-load-balancer-controller-policy.json

# Create IAM service account
eksctl create iamserviceaccount \
  --cluster kube-platform \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::123456789012:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=kube-platform \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

### Cluster Autoscaler

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=kube-platform \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::123456789012:role/ClusterAutoscalerRole
```

---

## Upgrading the Cluster

```bash
# Check current version
kubectl version

# Upgrade control plane (one minor version at a time)
eksctl upgrade cluster \
  --name kube-platform \
  --region us-east-1 \
  --version 1.33 \
  --approve

# Upgrade node groups
eksctl upgrade nodegroup \
  --cluster kube-platform \
  --region us-east-1 \
  --name standard-workers
```

---

## Cleanup

```bash
# Delete all add-ons first
aws eks delete-addon --cluster-name kube-platform --addon-name aws-ebs-csi-driver --region us-east-1
aws eks delete-addon --cluster-name kube-platform --addon-name coredns --region us-east-1
aws eks delete-addon --cluster-name kube-platform --addon-name kube-proxy --region us-east-1

# Delete IAM service accounts
eksctl delete iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster kube-platform \
  --region us-east-1

# Delete the cluster (deletes node groups and VPC if created by eksctl)
eksctl delete cluster \
  --name kube-platform \
  --region us-east-1

# This takes 10–15 minutes
```

**Important:** If you created resources outside of eksctl (e.g., ALBs, EBS volumes), delete them manually before deleting the cluster to avoid dangling resources and ongoing charges.

---

## Cost Estimation

| Resource | Approximate Cost (us-east-1) |
|----------|------------------------------|
| EKS Control Plane | $0.10/hour (~$72/month) |
| t3.medium worker node | $0.0416/hour (~$30/month each) |
| 3× t3.medium nodes | ~$90/month |
| EBS gp3 (50 GB per node) | ~$4/month per node |
| **Total (3-node cluster)** | **~$185/month** |

Use spot instances for non-critical workloads to reduce costs by 60–80%.
