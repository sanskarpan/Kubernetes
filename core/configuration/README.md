# Kubernetes Configuration: ConfigMaps and Secrets

## ConfigMap

A ConfigMap stores non-confidential configuration data as key-value pairs. The data can be consumed by pods as:
- Environment variables
- Command-line arguments
- Files mounted in a volume

ConfigMaps decouple configuration from container images, allowing the same image to run with different configurations across environments (dev, staging, production) by changing only the ConfigMap.

### ConfigMap Use Cases

**Application configuration:**
```yaml
data:
  LOG_LEVEL: "info"
  DATABASE_HOST: "mysql.database.svc.cluster.local"
  FEATURE_FLAGS: "new-ui=true,dark-mode=false"
```

**Configuration files (nginx.conf, application.yaml, etc.):**
```yaml
data:
  nginx.conf: |
    server {
      listen 8080;
      location / {
        root /usr/share/nginx/html;
      }
    }
```

**Scripts (entrypoint.sh, init.sh):**
```yaml
data:
  entrypoint.sh: |
    #!/bin/bash
    set -euo pipefail
    echo "Starting application..."
    exec "$@"
```

### ConfigMap Size Limit

ConfigMaps have a 1 MiB data size limit. For larger configurations (e.g., large CA bundles, model weights), use a volume mount from a PVC or an init container to fetch the data.

---

## Secret Types

| Type | Description | Use Case |
|---|---|---|
| `Opaque` | Arbitrary key-value data | Passwords, API keys, tokens |
| `kubernetes.io/tls` | TLS certificate and private key | TLS termination |
| `kubernetes.io/dockerconfigjson` | Docker registry credentials | Pull images from private registries |
| `kubernetes.io/service-account-token` | Service account token | Deprecated — use TokenRequest API |
| `kubernetes.io/ssh-auth` | SSH private key | SSH authentication |
| `kubernetes.io/basic-auth` | Username + password | HTTP basic auth |

### Creating Secrets Imperatively (Preferred for Production)

Never write real secret values in YAML files that end up in version control. Use `kubectl` directly or a secrets management tool:

```bash
# Create an Opaque secret from literal values:
kubectl create secret generic app-secret \
  --from-literal=DB_PASSWORD='my-secure-password' \
  --from-literal=API_KEY='my-api-key' \
  -n workloads

# Create from a file (the filename becomes the key):
kubectl create secret generic tls-certs \
  --from-file=tls.crt \
  --from-file=tls.key \
  -n workloads

# View the secret (values are base64-encoded):
kubectl get secret app-secret -n workloads -o yaml

# Decode a value:
kubectl get secret app-secret -n workloads \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

---

## How to Reference ConfigMaps and Secrets in Pods

### Method 1: Environment Variables (Simple, but Limited)

```yaml
containers:
  - name: app
    env:
      # Individual key from a ConfigMap:
      - name: LOG_LEVEL
        valueFrom:
          configMapKeyRef:
            name: app-config
            key: LOG_LEVEL

      # Individual key from a Secret:
      - name: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: app-secret
            key: DB_PASSWORD

      # All keys from a ConfigMap as env vars (bulk import):
    envFrom:
      - configMapRef:
          name: app-config
      - secretRef:
          name: app-secret
```

### Method 2: Volume Mounts (Recommended for Secrets and Config Files)

```yaml
volumes:
  - name: config-volume
    configMap:
      name: app-config
  - name: secret-volume
    secret:
      secretName: app-secret
      defaultMode: 0400   # Read-only by owner. Do not use 0644 for secrets.

containers:
  - name: app
    volumeMounts:
      - name: config-volume
        mountPath: /etc/config
        readOnly: true
      - name: secret-volume
        mountPath: /etc/secrets
        readOnly: true
```

**In the container:**
- `/etc/config/LOG_LEVEL` — file containing the value `info`
- `/etc/config/nginx.conf` — file containing the full nginx configuration
- `/etc/secrets/DB_PASSWORD` — file containing the password

---

## WARNING: Mount Secrets as Volumes, NOT Environment Variables

This is one of the most important security practices in Kubernetes.

### Why Environment Variables Are Risky for Secrets

**1. /proc/<pid>/environ leaks env vars:**
Any process on the same node that can read `/proc/<pid>/environ` can see all environment variables of a running process. In a multi-tenant cluster, this is a serious risk.

```bash
# On the node, any user with root (or CAP_SYS_PTRACE) can read:
cat /proc/<nginx-pid>/environ | tr '\0' '\n'
# Output includes: DB_PASSWORD=supersecret
```

**2. Environment variables are logged:**
Many applications (and frameworks) dump their environment to logs on startup for debugging. If `DB_PASSWORD` is an env var, it will appear in your log aggregation platform (Elasticsearch, Datadog, Splunk) in plain text.

**3. Child process inheritance:**
Environment variables are inherited by all child processes. If your app spawns a subprocess (a shell, a third-party tool, a forked worker), that child inherits all secrets.

**4. Heap dumps and core dumps:**
Environment variables are stored in the process's memory space. Core dumps and heap dumps contain the full memory image, including all environment variables.

**Contrast with volume-mounted secrets:**
- Files at `/etc/secrets/DB_PASSWORD` are not in the process environment.
- They are not inherited by child processes.
- They are not typically logged by frameworks.
- They update automatically when the Secret is rotated (with a short kubelet sync delay, typically 60s), without requiring a pod restart.
- Access can be restricted with file permissions (mode 0400).

### Correct Pattern (Volume Mount)

```yaml
spec:
  volumes:
    - name: db-credentials
      secret:
        secretName: app-secret
        items:
          - key: DB_PASSWORD
            path: db-password   # Mounted at /etc/secrets/db-password
            mode: 0400          # Read-only by owner only
  containers:
    - name: app
      volumeMounts:
        - name: db-credentials
          mountPath: /etc/secrets
          readOnly: true
```

Your application reads the password from `/etc/secrets/db-password`:
```python
with open('/etc/secrets/db-password', 'r') as f:
    password = f.read().strip()
```

---

## base64 Encoding Is NOT Encryption

This cannot be overstated: the `data` field in a Kubernetes Secret stores values as base64-encoded strings. **Base64 is an encoding, not encryption.** Anyone with read access to the Secret object can trivially decode the values.

```bash
echo "dGVzdC1wYXNzd29yZA==" | base64 -d
# Output: test-password
```

**Secrets at rest are encrypted** only if you configured etcd encryption at rest (via the `EncryptionConfiguration` API resource) **AND** your etcd is encrypted. By default, Kubernetes clusters do NOT encrypt Secrets at rest in etcd.

**Access control:** The primary protection for Secrets is RBAC. Use RBAC to restrict which ServiceAccounts and users can read Secrets, and limit access to named resources using `resourceNames`:

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["app-secret"]   # Only this specific Secret, not all Secrets
```

---

## Production Recommendations for Secret Management

### Option 1: SealedSecrets (GitOps-Friendly)
SealedSecrets encrypts Kubernetes Secrets using a public key. Only the SealedSecret controller (running in-cluster) can decrypt them using its private key. You can safely commit `SealedSecret` YAML files to git.

```bash
# Install kubeseal CLI and the controller:
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Seal a secret:
kubectl create secret generic app-secret --dry-run=client \
  --from-literal=DB_PASSWORD='secret' -o yaml | \
  kubeseal --controller-name=sealed-secrets -o yaml > sealed-app-secret.yaml

# Commit sealed-app-secret.yaml to git safely.
```

### Option 2: External Secrets Operator (ESO)
ESO syncs secrets from external stores (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault, Azure Key Vault) into Kubernetes Secrets automatically. The secret values never live in git — only the reference to the external store does.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: app-secret
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: production/app/db-password
```

### Option 3: HashiCorp Vault with the Vault Agent Injector
The Vault Agent Injector mutates pod specs to inject a sidecar container that authenticates to Vault and writes secrets to a shared volume that the main container can read.

### Option 4: etcd Encryption at Rest
Configure Kubernetes to encrypt Secret objects in etcd using AES-CBC or AES-GCM. This protects against attackers who gain access to etcd backups or the etcd data directory.

```yaml
# /etc/kubernetes/encryption-config.yaml (on the control plane)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}   # Fallback for existing unencrypted secrets
```

---

## Related Files

- `configmap.yml` — Production ConfigMap example with multiple data formats
- `secret.yml` — Educational Secret example (read all warnings before use)
- `resource-quota.yml` — ResourceQuota enforcing aggregate namespace limits
