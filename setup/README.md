# Cluster Setup — Choosing the Right Method

This directory contains setup guides and automation scripts for every major Kubernetes provisioning method. Use the comparison table below to decide which approach fits your situation, then follow the linked guide.

---

## Comparison Table

| | **KIND** | **Minikube** | **kubeadm** | **EKS (eksctl)** |
|---|---|---|---|---|
| **What it is** | Kubernetes in Docker — runs the entire cluster as containers | Single-node (or multi-node) cluster using a VM or Docker | Official tool to bootstrap a "real" cluster on bare VMs/servers | Managed Kubernetes control plane on AWS |
| **Control plane managed by** | You (via Docker) | You (via minikube CLI) | You (full responsibility) | AWS |
| **Best for** | Local dev, CI pipelines, learning multi-node topologies | Local dev, add-on experimentation, demos | Learning kubeadm internals, home-lab, on-prem | Production workloads in AWS |
| **Platform support** | Linux, macOS, Windows (Docker Desktop) | Linux, macOS, Windows | Linux VMs / bare metal | AWS cloud |
| **Multi-node support** | Yes (via config) | Limited (experimental) | Yes (unlimited) | Yes (node groups) |
| **Persistence across restarts** | No (containers restart) | Yes (VM disk) | Yes | Yes |
| **Resource usage** | Very low (shares Docker daemon) | Medium (VM overhead) | Medium–High (full OS per node) | Pay-per-node |
| **Setup time** | ~2 minutes | ~5 minutes | ~30–60 minutes | ~20–30 minutes |
| **Ingress support** | Yes (port mapping in config) | Yes (minikube addons enable ingress) | Yes (install separately) | Yes (ALB/NLB Ingress Controller) |
| **Load balancer support** | Requires MetalLB or cloud-provider-kind | Requires minikube tunnel | Requires MetalLB | Native (ELB) |
| **Persistent volumes** | hostPath via extraMounts | hostPath / minikube mount | Manual PV or CSI driver | EBS CSI Driver |
| **Add-ons / ecosystem** | Manual Helm installs | Built-in addon system | Manual installs | AWS Marketplace / add-ons |
| **Production-grade** | No | No | Possible (with effort) | Yes |
| **Cost** | Free | Free | Free (infra cost only) | AWS pricing |
| **Guide** | [setup/local/kind/](local/kind/README.md) | [setup/local/minikube/](local/minikube/README.md) | [setup/kubeadm/](kubeadm/README.md) | [setup/cloud/eks/](cloud/eks/README.md) |

---

## When to Use Each

### KIND — Use for:
- Running this repository's examples locally.
- CI pipelines (GitHub Actions, GitLab CI) that need a real cluster.
- Testing multi-node behavior without VMs.
- The fastest possible iteration loop during development.

**Not for:** anything that needs to survive a laptop restart, or workloads that need GPU/real persistent volumes.

### Minikube — Use for:
- Exploring Kubernetes add-ons (dashboard, metrics-server, registry, ingress) with one command.
- Demos and workshops where participants are on mixed OS (Linux/macOS/Windows).
- Experimenting with Kubernetes features without modifying your Docker setup.

**Not for:** CI pipelines (too slow to start), multi-node topology testing.

### kubeadm — Use for:
- Learning exactly how Kubernetes bootstrapping works under the hood.
- Building a home-lab or on-premises cluster on real or virtual machines.
- Interview preparation — kubeadm questions come up frequently.
- Bare-metal production clusters (combined with a CNI like Calico and a storage solution).

**Not for:** quick local dev (use KIND instead). kubeadm clusters require manual upgrades, etcd backups, and node maintenance.

### EKS (eksctl) — Use for:
- Production workloads on AWS.
- Teams that need managed control-plane updates, AWS IAM integration, and native load balancers.
- Workloads that need EBS/EFS persistent storage, AWS Secrets Manager integration, or Fargate serverless nodes.

**Not for:** local development, cost-sensitive learning environments, or workloads with multi-cloud requirements.

---

## Quick Decision Tree

```
Do you need it to run in production?
  YES → Is it on AWS?
          YES → EKS
          NO  → kubeadm (on-prem) or EKS alternative (GKE/AKS)
  NO  → Is it for CI or local dev?
          CI → KIND
          Local dev → KIND (fastest) or Minikube (best add-on ecosystem)
```

---

## Directory Index

| Directory | Method | Guide |
|-----------|--------|-------|
| `local/kind/` | KIND | [README](local/kind/README.md) |
| `local/minikube/` | Minikube | [README](local/minikube/README.md) |
| `cloud/eks/` | EKS | [README](cloud/eks/README.md) |
| `kubeadm/` | kubeadm | [README](kubeadm/README.md) |
