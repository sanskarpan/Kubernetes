# Minikube — Local Kubernetes Cluster

Minikube runs a single-node (or multi-node) Kubernetes cluster locally using a VM, Docker, or Podman as the driver. It is the easiest way to get a cluster with built-in add-ons like the Dashboard, metrics-server, and Ingress.

---

## Prerequisites

| Tool | Minimum Version | Notes |
|------|-----------------|-------|
| `minikube` | 1.35.0 | The minikube binary |
| `kubectl` | 1.30.0 | Kubernetes CLI |
| Docker | 24.0+ | Recommended driver on all platforms |
| VirtualBox or HyperKit | Any | Alternative VM drivers |
| CPU | 2+ cores | Recommended: 4 |
| RAM | 2 GB+ free | Recommended: 8 GB |
| Disk | 20 GB+ free | — |

---

## Linux Installation

### Step 1 — Install kubectl

```bash
# Download the latest stable release
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

# Verify checksum
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

# Install
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client
```

For arm64:

```bash
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/arm64/kubectl"
```

### Step 2 — Install minikube

```bash
# amd64
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install -o root -g root -m 0755 minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64

# arm64
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-arm64
sudo install -o root -g root -m 0755 minikube-linux-arm64 /usr/local/bin/minikube
rm minikube-linux-arm64

# Verify
minikube version
```

### Step 3 — Start minikube (Linux)

Docker is the recommended driver on Linux (avoids VM overhead):

```bash
# Ensure Docker is running
sudo systemctl status docker

# Start minikube with Docker driver
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=8192 \
  --disk-size=20g \
  --kubernetes-version=v1.32.0

# Verify
kubectl get nodes
```

If you prefer a VM driver (VirtualBox):

```bash
minikube start \
  --driver=virtualbox \
  --cpus=4 \
  --memory=8192 \
  --kubernetes-version=v1.32.0
```

---

## Windows Installation

### Step 1 — Install kubectl

**Using winget (Windows Package Manager):**

```powershell
winget install Kubernetes.kubectl
```

**Using Chocolatey:**

```powershell
choco install kubernetes-cli
```

**Using Scoop:**

```powershell
scoop install kubectl
```

**Manual:**

```powershell
# Download
curl.exe -LO "https://dl.k8s.io/release/v1.32.0/bin/windows/amd64/kubectl.exe"

# Move to a directory on your PATH
mkdir -Force C:\kubectl
Move-Item kubectl.exe C:\kubectl\

# Add C:\kubectl to your system PATH (System Properties > Environment Variables)
```

Verify:

```powershell
kubectl version --client
```

### Step 2 — Install minikube

**Using winget:**

```powershell
winget install Kubernetes.minikube
```

**Using Chocolatey:**

```powershell
choco install minikube
```

**Manual installer:**

1. Download `minikube-installer.exe` from: https://github.com/kubernetes/minikube/releases/latest
2. Run the installer as Administrator.
3. Restart your terminal.

### Step 3 — Start minikube (Windows)

**Recommended driver: Docker Desktop (Hyper-V backend) or Hyper-V.**

Ensure Docker Desktop is running, then:

```powershell
minikube start `
  --driver=docker `
  --cpus=4 `
  --memory=8192 `
  --kubernetes-version=v1.32.0
```

With Hyper-V (requires Windows Pro/Enterprise, run as Administrator):

```powershell
minikube start `
  --driver=hyperv `
  --cpus=4 `
  --memory=8192 `
  --kubernetes-version=v1.32.0
```

Verify:

```powershell
kubectl get nodes
minikube status
```

---

## Enable Common Add-ons

Minikube ships with a large collection of built-in add-ons. Enable the ones you need:

```bash
# NGINX Ingress Controller
minikube addons enable ingress

# Kubernetes Metrics Server (required for kubectl top and HPA)
minikube addons enable metrics-server

# Kubernetes Dashboard (web UI)
minikube addons enable dashboard

# Storage provisioner (for dynamic PVC provisioning)
minikube addons enable storage-provisioner

# Registry (local Docker registry inside the cluster)
minikube addons enable registry

# MetalLB (software load balancer — makes LoadBalancer Services work locally)
minikube addons enable metallb

# Default StorageClass
minikube addons enable default-storageclass
```

List all available add-ons:

```bash
minikube addons list
```

---

## Access the Dashboard

```bash
# Opens in your default browser
minikube dashboard

# Get the URL without opening a browser
minikube dashboard --url
```

---

## Ingress Usage

After enabling the Ingress add-on, get minikube's IP:

```bash
minikube ip
# Example output: 192.168.49.2
```

Add an entry to `/etc/hosts` (Linux/macOS) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
192.168.49.2  myapp.local
```

Then create an Ingress resource with `host: myapp.local` and access it at `http://myapp.local`.

---

## LoadBalancer Services

By default, `LoadBalancer` type Services remain in `<pending>` state locally. Use one of these approaches:

**Option A — minikube tunnel** (recommended, works on all platforms):

```bash
# Run in a separate terminal (requires sudo on Linux)
minikube tunnel
```

**Option B — MetalLB add-on:**

```bash
minikube addons enable metallb
minikube addons configure metallb
# Enter the IP range from your minikube IP subnet, e.g. 192.168.49.100-192.168.49.110
```

---

## Useful minikube Commands

```bash
# Start the cluster
minikube start

# Stop the cluster (preserves state)
minikube stop

# Delete the cluster
minikube delete

# Get cluster status
minikube status

# SSH into the node
minikube ssh

# Get the cluster IP
minikube ip

# Open a service in the browser
minikube service <service-name> -n <namespace>

# Get the URL of a service
minikube service <service-name> -n <namespace> --url

# View cluster logs
minikube logs

# Set default driver (so you don't need --driver each time)
minikube config set driver docker

# View current config
minikube config view

# Update minikube
minikube update-check
# Then re-download the binary

# Pause the cluster (frees resources without losing state)
minikube pause

# Unpause
minikube unpause

# Mount a host directory into the cluster
minikube mount /host/path:/vm/path

# Load a local Docker image into the cluster
minikube image load my-image:tag
```

---

## Multi-node Minikube (experimental)

Minikube supports multi-node clusters (experimental):

```bash
minikube start --nodes=3 --driver=docker --kubernetes-version=v1.32.0
kubectl get nodes
```

Note: multi-node support is less stable than KIND for local multi-node testing.

---

## Cleanup

```bash
# Stop the cluster (preserves data)
minikube stop

# Delete the cluster completely
minikube delete

# Delete all minikube clusters and profiles
minikube delete --all --purge
```
