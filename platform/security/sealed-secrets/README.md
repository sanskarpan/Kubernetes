# Sealed Secrets

## Overview

Sealed Secrets solves the "Kubernetes Secret in Git" problem. Kubernetes Secrets are base64-encoded (not encrypted) — committing them to a Git repository exposes your credentials to anyone with repository access.

Sealed Secrets encrypts secrets asymmetrically: only the Sealed Secrets controller running in your cluster can decrypt them. The encrypted SealedSecret objects ARE safe to commit to Git.

---

## How It Works

```
Developer workstation                    Kubernetes cluster
─────────────────────                    ─────────────────
                                         ┌────────────────────────────┐
kubeseal CLI ──fetches public key──────► │ sealed-secrets-controller  │
                                         │   (holds private key)      │
     │                                   └────────────────────────────┘
     │ encrypts Secret                          │
     ▼                                          │
SealedSecret.yaml ──git commit──► Git ──apply──► API Server
(safe to commit)                                │
                                                ▼
                                         sealed-secrets-controller
                                         decrypts → creates Secret
                                                │
                                                ▼
                                           Pod reads Secret
```

1. The controller generates an **RSA key pair** at startup. The private key is stored in a Kubernetes Secret in the sealed-secrets namespace. The public key is publicly accessible.
2. `kubeseal` fetches the public key from the controller and uses it to encrypt a Kubernetes Secret spec into a SealedSecret.
3. You commit the SealedSecret YAML to Git. The encrypted values cannot be decrypted without the controller's private key.
4. When you apply the SealedSecret, the controller decrypts it and creates a regular Kubernetes Secret in the same namespace.

---

## Installation (Helm)

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller

# Verify the controller is running
kubectl get pods -n kube-system | grep sealed-secrets
```

---

## Installing the kubeseal CLI

### macOS

```bash
brew install kubeseal
```

### Linux

```bash
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
  | jq -r .tag_name)
curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION#v}-linux-amd64.tar.gz" \
  | tar xz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### Verify

```bash
kubeseal --version
```

---

## Sealing a Secret

### Method 1: From literal values (use the included script)

```bash
./seal-secret.sh app-secret workloads DB_PASSWORD=mypassword API_KEY=xyz123
```

### Method 2: From an existing Secret file

```bash
# Create a dry-run Secret and pipe to kubeseal
kubectl create secret generic app-secret \
  --namespace workloads \
  --from-literal=DB_PASSWORD=mypassword \
  --from-file=tls.crt=./cert.pem \
  --dry-run=client \
  -o yaml \
| kubeseal \
  --namespace workloads \
  --format yaml \
  > sealed-app-secret.yaml

# Review the SealedSecret
cat sealed-app-secret.yaml

# Commit to Git (safe — values are encrypted)
git add sealed-app-secret.yaml
git commit -m "feat: add sealed secret for app credentials"

# Apply to cluster
kubectl apply -f sealed-app-secret.yaml
```

### Method 3: From an existing Secret in the cluster

```bash
kubectl get secret app-secret -n workloads -o yaml \
| kubeseal --format yaml \
> sealed-app-secret.yaml
```

---

## Namespace and Cluster Scoping

By default, a SealedSecret is bound to a specific **namespace AND cluster**. The encrypted value cannot be decrypted in a different namespace or a different cluster (even with the same Sealed Secrets version).

### Namespace-scoped (default)

```bash
kubeseal --namespace workloads --format yaml
```

The resulting SealedSecret can only be decrypted in the `workloads` namespace.

### Cluster-scoped (portable across namespaces)

```bash
kubeseal --scope cluster-wide --format yaml
```

The SealedSecret can be applied to any namespace. The annotation `sealedsecrets.bitnami.com/cluster-wide: "true"` is added automatically.

### Namespace-scoped but any cluster

```bash
kubeseal --scope namespace-wide --format yaml
```

Decryptable in the `workloads` namespace of any cluster that has the same controller private key.

---

## Key Rotation Procedure

Sealed Secrets automatically rotates the controller key every **30 days** by default. New SealedSecrets are encrypted with the latest key. Old keys are retained so that existing SealedSecrets can still be decrypted.

### Manual key rotation

```bash
# Force generation of a new key immediately
kubectl annotate secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
  sealedsecrets.bitnami.com/rotate-key=true

# Restart the controller to pick up the new key
kubectl rollout restart deployment sealed-secrets-controller -n kube-system

# Fetch the new public key and re-seal all secrets
kubeseal --fetch-cert --controller-namespace kube-system > pub-key.pem
```

After rotation, existing SealedSecrets still work (old keys are kept). Re-seal them with the new key for security hygiene.

---

## WARNING: Back Up the Private Key

**CRITICAL: If the controller's private key is lost, all SealedSecrets become permanently unreadable.**

Back up the private key immediately after installation:

```bash
# Export the private key (treat this as a highly sensitive secret)
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key.yaml

# Store encrypted in a secure vault (1Password, AWS Secrets Manager, HashiCorp Vault)
# NEVER commit this file to Git
```

Store the backup in a secure, offline location separate from the cluster. Consider using multiple backup storage locations.

---

## Comparison: Sealed Secrets vs External Secrets Operator

| Feature | Sealed Secrets | External Secrets Operator (ESO) |
|---------|---------------|--------------------------------|
| Secret storage | Encrypted in Git (SealedSecret CRDs) | External systems (AWS SM, Vault, GCP SM, etc.) |
| Encryption approach | RSA asymmetric (controller holds private key) | Delegates to external system |
| Git-native | Yes — SealedSecrets are committed to Git | No — manifests reference external secrets by name |
| Multi-cluster support | Complex (key sharing or re-sealing) | Native (same external secret, multiple clusters) |
| Secret sync | One-time at apply time | Continuous sync (can detect rotation) |
| Auto-rotation | Not built-in | Yes — syncs new values from external system |
| Infrastructure requirement | Sealed Secrets controller only | ESO + external secret store (Vault, AWS SM, etc.) |
| Best for | Small teams, GitOps-first workflows | Enterprises with existing secret management infrastructure |

**Choose Sealed Secrets if:** You want pure GitOps with no external dependencies.
**Choose ESO if:** You already use Vault, AWS Secrets Manager, or similar, and want automatic secret rotation.
