# ArgoCD Installation and Configuration Guide

## Prerequisites

- Kubernetes cluster (>= 1.25)
- `kubectl` configured to talk to the cluster
- `helm` >= 3.0 installed
- `argocd` CLI installed (see below)

---

## Install the ArgoCD CLI

```bash
# macOS
brew install argocd

# Linux
curl -sSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd

# Verify
argocd version --client
```

---

## Install ArgoCD via Helm (Recommended for Production)

The Helm chart gives you full control over configuration via values.

```bash
# Add the ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create the namespace
kubectl create namespace argocd

# Install ArgoCD with production settings
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.7.0 \
  --set global.image.tag="v2.13.0" \
  --set configs.params."server.insecure"=false \
  --set server.service.type=ClusterIP \
  --wait \
  --timeout 10m
```

### Key Production Values to Override

Create a `values-argocd-prod.yaml`:

```yaml
global:
  image:
    # Pin to a specific ArgoCD version — never use :latest in production
    tag: "v2.13.0"

configs:
  params:
    # Never run ArgoCD server without TLS in production
    server.insecure: false
  cm:
    # Restrict which repositories ArgoCD can read (allowlist)
    repositories: |
      - url: https://github.com/your-org/your-repo.git
        name: your-repo

server:
  # Use ClusterIP + Ingress in production (not LoadBalancer)
  service:
    type: ClusterIP
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: argocd.example.com
    tls: true

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi

applicationSet:
  enabled: true

notifications:
  enabled: true
```

```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  -f values-argocd-prod.yaml \
  --atomic \
  --timeout 10m
```

---

## Alternative: Install via Raw Manifests

For quick cluster bootstrapping (not recommended for production):

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

## Accessing the ArgoCD UI

### Port-Forward (Development)

```bash
# Forward the ArgoCD server to localhost
kubectl port-forward svc/argocd-server \
  -n argocd \
  8080:443

# Open in browser
open https://localhost:8080
```

### Get the Initial Admin Password

The default admin password is auto-generated and stored as a Secret.

```bash
# Get the initial password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# IMPORTANT: Change the password immediately after first login
argocd account update-password
```

### Via Ingress (Production)

After configuring Ingress, access ArgoCD at your configured hostname:

```
https://argocd.example.com
```

---

## CLI Login

```bash
# Login via the UI hostname (production)
argocd login argocd.example.com

# Login via port-forward (development)
argocd login localhost:8080 --insecure

# Using SSO (if configured)
argocd login argocd.example.com --sso
```

---

## Connecting a Git Repository

ArgoCD needs credentials to pull from private repositories.

### HTTPS Repository

```bash
argocd repo add https://github.com/your-org/your-repo.git \
  --username your-user \
  --password your-token    # Use a GitHub PAT with 'repo' scope
```

### SSH Repository

```bash
# Add using an SSH private key
argocd repo add git@github.com:your-org/your-repo.git \
  --ssh-private-key-path ~/.ssh/id_rsa
```

### Declarative (GitOps way — preferred)

Create a Secret in the `argocd` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  url: https://github.com/your-org/your-repo.git
  password: <github-pat>   # Use External Secrets Operator in production
  username: not-used
```

```bash
kubectl apply -f my-repo-creds.yaml
```

---

## Creating Your First Application

### Via the CLI

```bash
argocd app create apache \
  --repo https://github.com/your-org/your-repo.git \
  --path helm/apache \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace webapps \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --helm-set replicaCount=2
```

### Via a Manifest (Preferred — GitOps)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apache
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: helm/apache
    helm:
      valueFiles:
        - values.yaml
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: webapps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f gitops/argocd/apps/apache.yml -n argocd
```

---

## Common ArgoCD CLI Commands

```bash
# List all applications
argocd app list

# Get application details and sync status
argocd app get apache

# Manually sync an application (force reconciliation)
argocd app sync apache

# Wait for sync to complete
argocd app wait apache --sync --health

# View application diff (what would change)
argocd app diff apache

# Rollback to a previous deployment
argocd app rollback apache

# View application history
argocd app history apache

# Hard refresh (bypass cache, fetch latest from Git)
argocd app get apache --hard-refresh

# Delete an application (does NOT delete cluster resources)
argocd app delete apache

# Delete application AND cluster resources
argocd app delete apache --cascade
```

---

## Troubleshooting

```bash
# Check ArgoCD component status
kubectl get pods -n argocd

# View ArgoCD server logs
kubectl logs -n argocd deployment/argocd-server -f

# View application controller logs (reconciliation)
kubectl logs -n argocd deployment/argocd-application-controller -f

# View repo server logs (template rendering)
kubectl logs -n argocd deployment/argocd-repo-server -f

# Describe a failing application
argocd app get apache --output json | jq .status.conditions
```
