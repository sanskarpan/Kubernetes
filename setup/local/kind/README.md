# KIND — Kubernetes in Docker

KIND (Kubernetes IN Docker) runs each Kubernetes node as a Docker container. It is the recommended method for running this repository's examples locally and in CI.

---

## Prerequisites

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| Docker | 24.0+ | Container runtime for KIND nodes |
| `kind` | 0.29.0 | Cluster lifecycle management |
| `kubectl` | 1.30.0+ | Cluster interaction |

---

## Quick Install (automated)

The `install.sh` script installs Docker (Linux only), KIND, and kubectl in an idempotent way. It skips tools that are already installed.

```bash
# Default versions
bash setup/local/kind/install.sh

# Override versions
KIND_VERSION=0.29.0 KUBECTL_VERSION=1.32.0 bash setup/local/kind/install.sh
```

---

## Manual Install

### macOS

```bash
# Homebrew (recommended)
brew install kind kubectl

# Verify
kind version
kubectl version --client
```

### Linux (amd64)

```bash
# KIND
KIND_VERSION="0.29.0"
curl -Lo /tmp/kind \
  "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64"
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind

# kubectl
KUBECTL_VERSION="1.32.0"
curl -Lo /tmp/kubectl \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
```

### Linux (arm64)

```bash
KIND_VERSION="0.29.0"
curl -Lo /tmp/kind \
  "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-arm64"
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind

KUBECTL_VERSION="1.32.0"
curl -Lo /tmp/kubectl \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/arm64/kubectl"
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
```

### Windows

```powershell
# With Chocolatey
choco install kind kubernetes-cli

# Or with Scoop
scoop install kind kubectl
```

---

## Create the Cluster

### Using the provided config (recommended)

The `kind-config.yml` in this directory creates a production-like 3-node cluster (1 control-plane + 2 workers) with port mappings for Ingress.

```bash
kind create cluster \
  --name kube-platform \
  --config setup/local/kind/kind-config.yml \
  --wait 120s
```

### Minimal single-node cluster

```bash
kind create cluster --name kube-platform
```

---

## Verify the Cluster

```bash
# Check nodes (should show 1 control-plane + 2 workers)
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system

# Check cluster info
kubectl cluster-info --context kind-kube-platform
```

Expected output:

```
NAME                           STATUS   ROLES           AGE   VERSION
kube-platform-control-plane    Ready    control-plane   2m    v1.32.0
kube-platform-worker           Ready    <none>          90s   v1.32.0
kube-platform-worker2          Ready    <none>          90s   v1.32.0
```

---

## Using Ingress

The KIND config maps host ports 8080 and 8443 to the control-plane container's ports 80 and 443. To use Ingress:

1. Install the NGINX Ingress Controller:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.0/deploy/static/provider/kind/deploy.yaml

# Wait for the controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

2. Create an Ingress resource pointing to your Service.

3. Access your application at `http://localhost:8080`.

---

## Loading Local Images

KIND clusters do not automatically have access to locally built Docker images. Use `kind load` to push images into the cluster nodes:

```bash
# Build an image
docker build -t my-app:latest .

# Load into KIND cluster
kind load docker-image my-app:latest --name kube-platform

# Reference in your manifest
# image: my-app:latest
# imagePullPolicy: Never
```

---

## Multiple Clusters

You can run multiple KIND clusters simultaneously (useful for testing multi-cluster scenarios):

```bash
kind create cluster --name cluster-a
kind create cluster --name cluster-b

# Switch between them
kubectl config use-context kind-cluster-a
kubectl config use-context kind-cluster-b

# List all contexts
kubectl config get-contexts
```

---

## Useful KIND Commands

```bash
# List clusters
kind get clusters

# Get nodes in a cluster
kind get nodes --name kube-platform

# Export kubeconfig
kind export kubeconfig --name kube-platform --kubeconfig /tmp/kube-platform.kubeconfig

# Inspect cluster logs
kind export logs --name kube-platform /tmp/kind-logs

# Delete cluster
kind delete cluster --name kube-platform

# Delete all clusters
kind delete clusters --all
```

---

## Troubleshooting

### Nodes stuck in NotReady

```bash
# Check events
kubectl get events -n kube-system --sort-by='.lastTimestamp'

# Describe a node
kubectl describe node kube-platform-control-plane
```

### Port 8080 already in use

Edit `kind-config.yml` and change the `hostPort` value, or stop the conflicting process:

```bash
sudo lsof -i :8080
```

### Docker not running

```bash
# macOS / Linux
docker info
# Start Docker Desktop (macOS) or: sudo systemctl start docker (Linux)
```

### KIND cluster creation times out

Increase the `--wait` flag or check Docker has enough resources (recommended: 4 CPU, 8 GB RAM).

---

## Cleanup

```bash
kind delete cluster --name kube-platform
```

Or using the Makefile:

```bash
make cluster-down
```
