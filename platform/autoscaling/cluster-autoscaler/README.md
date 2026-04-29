# Cluster Autoscaler

## What Cluster Autoscaler Does

The Cluster Autoscaler (CA) watches for pods that cannot be scheduled due to insufficient resources (CPU, memory, or custom node affinities). When it finds unschedulable pods, it adds nodes to the cluster by scaling up a node group (AWS Auto Scaling Group, GKE node pool, AKS node pool, etc.).

CA also removes nodes that have been underutilized for a configurable period. A node is considered underutilized when the sum of resource requests from all its pods is below a threshold (default: 50% of node capacity for both CPU and memory).

**Important**: CA works on resource **requests**, not actual usage. Pods without resource requests are invisible to CA's scale-up logic.

## AWS EKS Setup

### 1. IAM Permissions

The CA needs permission to describe and modify Auto Scaling Groups. Create an IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    }
  ]
}
```

Attach this policy to the node group's IAM role, or use IRSA (IAM Roles for Service Accounts) to assign it to the CA pod directly.

### 2. Node Group ASG Tags

Tag the Auto Scaling Group so CA can discover and manage it:

```
k8s.io/cluster-autoscaler/enabled: "true"
k8s.io/cluster-autoscaler/<cluster-name>: "owned"
```

With managed node groups (`eksctl` or Terraform `aws_eks_node_group`), these tags are applied automatically.

### 3. Install CA (EKS)

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=<your-cluster-name> \
  --set awsRegion=us-east-1 \
  --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<IRSA_ROLE_ARN>
```

## GKE Setup

GKE has a built-in Cluster Autoscaler — no Helm chart needed. Enable it on a node pool:

```bash
# Enable autoscaling on an existing node pool
gcloud container clusters update <cluster-name> \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=10 \
  --node-pool=<pool-name> \
  --region=us-central1
```

Or via Terraform:

```hcl
resource "google_container_node_pool" "app_pool" {
  autoscaling {
    min_node_count = 1
    max_node_count = 10
  }
}
```

## AKS Setup

AKS also has a built-in autoscaler. Enable it on the node pool:

```bash
az aks nodepool update \
  --resource-group <rg> \
  --cluster-name <cluster> \
  --name <nodepool> \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 10
```

Or at cluster creation:

```bash
az aks create \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 10
```

## Key Configuration Flags

These flags apply to the CA Deployment (EKS/self-managed). GKE and AKS have equivalent settings via cloud console or CLI.

| Flag | Default | Description |
|---|---|---|
| `--scale-down-delay-after-add` | `10m` | Wait this long after adding a node before considering scale-down. Prevents immediate removal of newly added nodes. |
| `--scale-down-unneeded-time` | `10m` | A node must be underutilized for this long before CA removes it. |
| `--scale-down-utilization-threshold` | `0.5` | Fraction of node capacity (CPU and memory requests) below which a node is "unneeded". |
| `--max-node-provision-time` | `15m` | If a new node does not become Ready within this time, CA will retry. |
| `--skip-nodes-with-local-storage` | `true` | Do not remove nodes with pods that use local storage (emptyDir, hostPath). |
| `--skip-nodes-with-system-pods` | `true` | Do not remove nodes running kube-system pods (DaemonSets exempt). |
| `--expander` | `random` | Strategy for choosing which node group to expand. See Priority Expander below. |

## Priority Expander for Mixed Instance Types

The priority expander lets you rank node groups so CA prefers cheaper or more available instance types:

```yaml
# ConfigMap: cluster-autoscaler-priority-expander in kube-system
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-autoscaler-priority-expander
  namespace: kube-system
data:
  priorities: |
    100:
      - .*spot.*         # Prefer spot/preemptible instances (cheapest)
    50:
      - .*m5\.large.*    # Fall back to on-demand m5.large
    10:
      - .*              # Any other node group as last resort
```

Enable it with `--expander=priority`.

## Interaction with PodDisruptionBudgets

When CA drains a node for scale-down, it respects PodDisruptionBudgets (PDBs):

- CA simulates the eviction of each pod before draining and checks whether evicting it would violate any PDB.
- If evicting a pod would take an application below `minAvailable` or exceed `maxUnavailable`, CA **skips that node** and marks it as "blocked by PDB".
- This is why PDBs are essential for StatefulSets and critical Deployments: they prevent CA from inadvertently causing downtime during node rotation.

```yaml
# Example PDB that blocks CA from removing the last replica
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: myapp-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: myapp
```

See `core/workloads/statefulset/mysql-pdb.yml` for a StatefulSet-specific PDB example.

## Checking CA Activity

```bash
# View CA logs
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler --tail=100

# Check CA status
kubectl get configmap cluster-autoscaler-status -n kube-system -o yaml

# List node groups CA manages
kubectl describe configmap cluster-autoscaler-status -n kube-system
```
