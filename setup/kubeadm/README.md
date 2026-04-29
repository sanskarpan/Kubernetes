# kubeadm — Bootstrap a Production-Grade Cluster

This guide uses the 3-script approach to set up a Kubernetes cluster on Linux VMs or bare-metal machines using `kubeadm`. The scripts are designed to be run in order: common setup on all nodes, then master initialization, then worker join.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Control Plane Node (master)                             │
│  - kube-apiserver                                        │
│  - kube-controller-manager                               │
│  - kube-scheduler                                        │
│  - etcd                                                  │
│  - kubelet + containerd                                  │
└──────────────────────────┬───────────────────────────────┘
                           │
               ┌───────────┴───────────┐
               │                       │
┌──────────────▼──────────┐  ┌────────▼──────────────────┐
│  Worker Node 1          │  │  Worker Node 2             │
│  - kubelet + containerd │  │  - kubelet + containerd    │
│  - kube-proxy           │  │  - kube-proxy              │
└─────────────────────────┘  └────────────────────────────┘
```

---

## Prerequisites

| Requirement | Specification |
|-------------|---------------|
| OS | Ubuntu 22.04 LTS (or 24.04 LTS) |
| Control plane RAM | 2 GB minimum (4 GB recommended) |
| Worker RAM | 1 GB minimum (4 GB recommended) |
| CPU | 2+ vCPUs per node |
| Disk | 20 GB+ per node |
| Network | Full connectivity between all nodes |
| Ports (control plane) | 6443, 2379-2380, 10250-10252 |
| Ports (workers) | 10250, 30000-32767 |
| Unique hostname | Each node must have a unique hostname |
| MAC address | Each node must have a unique MAC address |
| Swap | Must be disabled |

---

## The 3-Script Approach

| Script | Runs On | Purpose |
|--------|---------|---------|
| `00-common.sh` | **All nodes** | Disables swap, installs containerd and Kubernetes packages |
| `01-master.sh` | **Control-plane only** | Initializes the cluster with kubeadm, installs Calico CNI |
| `02-worker.sh` | **Each worker node** | Joins the worker to the cluster |

---

## Step-by-Step Instructions

### Step 1 — Prepare all nodes

Run `00-common.sh` on **every node** (control-plane and all workers):

```bash
# Copy the script to each node
scp setup/kubeadm/00-common.sh user@<node-ip>:/tmp/

# SSH into each node and run
ssh user@<node-ip>
sudo bash /tmp/00-common.sh
```

Or override versions:

```bash
K8S_VERSION=1.32 K8S_FULL_VERSION=1.32.0 sudo bash /tmp/00-common.sh
```

What `00-common.sh` does:
1. Disables swap permanently (required by kubelet).
2. Loads required kernel modules: `overlay` and `br_netfilter`.
3. Configures sysctl for bridge traffic and IP forwarding.
4. Installs `containerd` from the official Docker repository.
5. Configures containerd to use `SystemdCgroup = true` (required for kubeadm).
6. Installs `kubelet`, `kubeadm`, and `kubectl` from the official Kubernetes apt repository.
7. Pins packages to prevent uncontrolled upgrades.

### Step 2 — Initialize the control plane

Run `01-master.sh` on the **control-plane node only**:

```bash
scp setup/kubeadm/01-master.sh user@<master-ip>:/tmp/
ssh user@<master-ip>
sudo bash /tmp/01-master.sh
```

Or with custom settings:

```bash
CONTROL_PLANE_IP=10.0.0.10 POD_CIDR=192.168.0.0/16 sudo bash /tmp/01-master.sh
```

What `01-master.sh` does:
1. Runs `kubeadm init` with the specified control-plane IP and pod CIDR.
2. Copies the kubeconfig to `~/.kube/config` for the current user.
3. Installs the Calico CNI plugin (compatible with the default pod CIDR `192.168.0.0/16`).
4. Waits for all system pods to become ready.
5. Prints the `kubeadm join` command for worker nodes.

**Save the join command** — you will need it in Step 3.

### Step 3 — Join worker nodes

Run `02-worker.sh` on **each worker node**, using the values printed by Step 2:

```bash
scp setup/kubeadm/02-worker.sh user@<worker-ip>:/tmp/
ssh user@<worker-ip>

# Set the values from the join command printed by 01-master.sh
export CONTROL_PLANE_ENDPOINT="10.0.0.10:6443"
export JOIN_TOKEN="abc123.xyz789..."
export CA_CERT_HASH="sha256:abcdef1234..."

sudo -E bash /tmp/02-worker.sh
```

What `02-worker.sh` does:
1. Runs `kubeadm reset` to clean any previous state.
2. Runs `kubeadm join` with the specified endpoint, token, and CA hash.
3. The worker registers with the control plane.

### Step 4 — Verify the cluster

Back on the **control-plane node**:

```bash
# Should show all nodes as Ready
kubectl get nodes -o wide

# Should show all system pods running
kubectl get pods -n kube-system

# Check Calico pods
kubectl get pods -n calico-system
```

Expected output (after all nodes are ready):

```
NAME              STATUS   ROLES           AGE   VERSION
master-node       Ready    control-plane   10m   v1.32.0
worker-node-1     Ready    <none>          5m    v1.32.0
worker-node-2     Ready    <none>          5m    v1.32.0
```

---

## Useful kubeadm Commands

```bash
# Re-generate the join command (if token expired)
kubeadm token create --print-join-command

# List tokens
kubeadm token list

# Check cluster status
kubeadm config view

# Upgrade kubeadm (step 1 of cluster upgrade)
apt-get update && apt-get install -y kubeadm=1.33.0-1.1

# Plan an upgrade
kubeadm upgrade plan

# Apply the upgrade (on control plane)
kubeadm upgrade apply v1.33.0

# Reset a node (destructive — removes all cluster state)
kubeadm reset --cri-socket unix:///var/run/containerd/containerd.sock
```

---

## etcd Backup

For production clusters, back up etcd regularly:

```bash
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify snapshot
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-*.db
```

---

## Troubleshooting

### Node stuck in NotReady

```bash
# Check kubelet status
systemctl status kubelet
journalctl -u kubelet -n 50

# Check containerd
systemctl status containerd

# Check events
kubectl describe node <node-name>
```

### kubeadm init fails — port already in use

```bash
# Check what is using port 6443
ss -tlnp | grep 6443

# Reset and retry
kubeadm reset --cri-socket unix:///var/run/containerd/containerd.sock
```

### Calico pods in CrashLoopBackOff

```bash
kubectl logs -n calico-system <calico-node-pod>
# Common cause: POD_CIDR mismatch — ensure 192.168.0.0/16 matches kubeadm init --pod-network-cidr
```

### Token expired (worker join fails)

```bash
# Generate a new token on the master
kubeadm token create --print-join-command
```
