# External Secrets Operator (ESO)

External Secrets Operator is the **2025 production standard** for secrets management in Kubernetes. It syncs secrets from external stores (AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, HashiCorp Vault) into native Kubernetes Secrets automatically.

## Why ESO Over SealedSecrets

| Dimension | SealedSecrets | External Secrets Operator |
|---|---|---|
| Production rating | Workable | Production standard |
| Secret storage | Encrypted in Git | Cloud provider (AWS SM, GCP SM, Azure KV) |
| Automatic rotation | No | Yes (configurable refresh interval) |
| Multi-cluster | Complex (one key pair per cluster) | Native (one cloud secret, many clusters) |
| Key management risk | Critical — losing private key = locked out | Delegated to cloud provider |
| Audit logging | K8s audit logs only | Cloud provider logs (CloudTrail, etc.) |
| Dynamic credentials | No | No (use Vault for this) |
| Operational complexity | Low | Medium |
| Best for | GitOps-first small teams | Cloud-native production teams |

**Recommendation:** Use ESO for production. Use SealedSecrets for local development or small GitOps-only teams. Use Vault only if you need dynamic credentials or a hard compliance audit requirement.

## Installation

```bash
# Add the ESO Helm repository
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install ESO (cluster-wide)
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true

# Verify installation
kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets
```

## Concepts

```
External Store (AWS SM / GCP SM / Azure KV / Vault)
         │
         │ ESO polls on refreshInterval
         ▼
   ExternalSecret (CR) ──→ reads from SecretStore/ClusterSecretStore
         │
         │ ESO creates/updates
         ▼
   Kubernetes Secret (native, auto-populated)
         │
         │ mounted by pod
         ▼
   Container environment / volume
```

### SecretStore vs ClusterSecretStore

- **SecretStore**: Namespaced. Can only be referenced by ExternalSecrets in the same namespace.
- **ClusterSecretStore**: Cluster-scoped. Can be referenced by ExternalSecrets in any namespace.

Use `ClusterSecretStore` for platform-wide secrets (certificates, shared credentials).
Use `SecretStore` for application-specific secrets with namespace isolation.

## AWS Secrets Manager Setup

### Step 1: Create IAM role with IRSA (IAM Roles for Service Accounts)

```bash
# Associate OIDC provider with the cluster (run once per cluster)
eksctl utils associate-iam-oidc-provider --region us-east-1 --cluster my-cluster --approve

# Create IAM policy for Secrets Manager access
aws iam create-policy \
  --policy-name ESO-SecretsManager-Policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:*:secret:production/*"
    }]
  }'

# Create ServiceAccount with IRSA annotation
eksctl create iamserviceaccount \
  --name external-secrets-sa \
  --namespace external-secrets \
  --cluster my-cluster \
  --attach-policy-arn arn:aws:iam::ACCOUNT_ID:policy/ESO-SecretsManager-Policy \
  --approve
```

### Step 2: Create a ClusterSecretStore

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
  annotations:
    kubernetes.io/description: "Cluster-wide SecretStore backed by AWS Secrets Manager"
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

### Step 3: Create an ExternalSecret

See `external-secret-example.yaml` for a complete example.

## Usage Pattern

```bash
# Create a secret in AWS Secrets Manager
aws secretsmanager create-secret \
  --name production/notes-app \
  --secret-string '{"db_password":"supersecret","api_key":"xyz123"}'

# Apply the ExternalSecret
kubectl apply -f platform/security/eso/external-secret-example.yaml

# Verify the K8s Secret was created
kubectl get secret notes-app-secret -n notes-app -o jsonpath='{.data}' | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(k,'=',base64.b64decode(v).decode()) for k,v in d.items()]"
```

## Automatic Rotation

ESO polls the external store on the `refreshInterval` schedule. When the secret changes in AWS/GCP/Azure:

1. ESO detects the new version on the next poll
2. ESO updates the Kubernetes Secret
3. **Important**: pods do NOT automatically restart when the Secret changes

### Force pod restart on secret rotation

```bash
# Option 1: Annotate the Deployment with the secret version (triggers rollout)
kubectl annotate deployment notes-app \
  secrets.kyverno.io/secret-version="$(date +%s)" --overwrite

# Option 2: Use Reloader (Stakater Reloader watches Secrets and auto-rolls pods)
helm install reloader stakater/reloader --namespace kube-system
# Then annotate the Deployment:
# annotations:
#   reloader.stakater.com/auto: "true"
```

## References

- [ESO Documentation](https://external-secrets.io/latest/)
- [ESO GitHub](https://github.com/external-secrets/external-secrets)
- [Supported Providers](https://external-secrets.io/latest/provider/aws-secrets-manager/)
