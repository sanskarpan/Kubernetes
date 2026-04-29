# Examples

This directory contains working, annotated Kubernetes manifests organised into learning
progressions. Each sub-directory builds on the previous one, introducing new concepts
and production requirements.

---

## Learning Paths

### Path 1: Platform Engineer (recommended order)

1. [`nginx-reference/01-intro/`](#1-nginx-intro) — Core Kubernetes objects: Pod, Deployment, Service
2. [`nginx-reference/02-production-baseline/`](#2-nginx-production-baseline) — Production requirements: security contexts, probes, PDB, NetworkPolicy, HPA
3. [`django-notes-app/`](#3-django-notes-app) — Full application: Dockerfile, multi-resource K8s deploy, Ingress, HPA

### Path 2: Application Developer

1. [`django-notes-app/`](#3-django-notes-app) — Deploy a real Django application to Kubernetes
2. [`nginx-reference/02-production-baseline/`](#2-nginx-production-baseline) — Understand the production requirements your platform team enforces

---

## Prerequisites

| Tool       | Version | Installation                             |
|------------|---------|------------------------------------------|
| kubectl    | >= 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| Helm       | >= 3.14 | https://helm.sh/docs/intro/install/     |
| Docker     | >= 24   | https://docs.docker.com/get-docker/     |
| minikube   | >= 1.32 | https://minikube.sigs.k8s.io/           |

### Start a Local Cluster

```bash
# Using minikube
minikube start --cpus=4 --memory=4g --driver=docker

# Using kind (Kubernetes in Docker)
kind create cluster --name kube-platform

# Verify
kubectl cluster-info
kubectl get nodes
```

---

## 1. Nginx Intro

**Path:** `nginx-reference/01-intro/`

**What you learn:**
- What a Pod is and how to create one
- What a Deployment is and why you should never run bare Pods in production
- What a Service is and how traffic routing works

**Files:**
| File             | Description                                         |
|------------------|-----------------------------------------------------|
| `pod.yml`        | Minimal nginx Pod — learning only, not for prod     |
| `deployment.yml` | Deployment with 1 replica — introductory            |
| `service.yml`    | NodePort Service to expose the Deployment           |
| `README.md`      | Step-by-step guide                                  |

**Quick start:**

```bash
# Apply all intro files
kubectl apply -f examples/nginx-reference/01-intro/

# Verify
kubectl get pods,svc

# Access via minikube
minikube service nginx-service

# Clean up
kubectl delete -f examples/nginx-reference/01-intro/
```

---

## 2. Nginx Production Baseline

**Path:** `nginx-reference/02-production-baseline/`

**What you learn:**
- Pod Security Standards (Restricted)
- Security contexts (runAsNonRoot, readOnlyRootFilesystem, capabilities drop)
- Resource requests and limits
- Liveness, readiness, and startup probes
- PodDisruptionBudget for HA during node drains
- HorizontalPodAutoscaler for traffic-based scaling
- NetworkPolicy for zero-trust networking

**Files:**
| File                 | Description                                             |
|----------------------|---------------------------------------------------------|
| `namespace.yml`      | Namespace with PSA labels enforcing Restricted policy   |
| `deployment.yml`     | Full production Deployment — all security contexts      |
| `service.yml`        | ClusterIP Service                                       |
| `hpa.yml`            | HPA with CPU + memory metrics and behavior block        |
| `pdb.yml`            | PodDisruptionBudget: minAvailable: 1                   |
| `network-policy.yml` | Default deny-all + allow ingress controller egress      |
| `README.md`          | Explanation of every field and why it exists            |

**Quick start:**

```bash
kubectl apply -f examples/nginx-reference/02-production-baseline/

# Monitor the HPA
kubectl get hpa -n production-baseline -w

# Test PDB (try to drain a node — should be blocked)
kubectl drain <node-name> --dry-run=client

# Clean up
kubectl delete -f examples/nginx-reference/02-production-baseline/
kubectl delete namespace production-baseline
```

---

## 3. Django Notes App

**Path:** `django-notes-app/`

**What you learn:**
- Multi-stage Dockerfile for Python applications
- Complete Kubernetes deployment for a stateful web application
- Ingress with TLS termination
- HPA for a web application
- ArgoCD GitOps integration

**Files:**
| File                  | Description                                              |
|-----------------------|----------------------------------------------------------|
| `Dockerfile`          | Multi-stage Python build (builder + runtime)             |
| `README.md`           | Architecture, build, and deployment guide                |
| `k8s/namespace.yml`   | notes-app namespace                                      |
| `k8s/deployment.yml`  | Production Django Deployment                             |
| `k8s/service.yml`     | ClusterIP Service                                        |
| `k8s/hpa.yml`         | HPA                                                      |
| `k8s/pdb.yml`         | PodDisruptionBudget                                      |
| `k8s/ingress.yml`     | Ingress with TLS                                         |

**Quick start:**

```bash
# Build the image locally (for minikube)
eval $(minikube docker-env)
docker build -t notes-app:local examples/django-notes-app/

# Deploy
kubectl apply -f examples/django-notes-app/k8s/

# Access via port-forward
kubectl port-forward svc/notes-app -n notes-app 8080:80

# Clean up
kubectl delete -f examples/django-notes-app/k8s/
kubectl delete namespace notes-app
```

---

## Conventions Used in These Examples

### Label Standard

All resources use the full `app.kubernetes.io/*` label set:

```yaml
labels:
  app.kubernetes.io/name: nginx           # The application name
  app.kubernetes.io/instance: nginx       # The release instance (unique per namespace)
  app.kubernetes.io/version: "1.27"       # The application version
  app.kubernetes.io/component: webserver  # The role of this resource
  app.kubernetes.io/part-of: nginx        # The larger system this belongs to
  app.kubernetes.io/managed-by: kubectl   # The tool managing this resource
```

### Security Baseline

Every production example enforces:

```yaml
# Pod-level
securityContext:
  runAsNonRoot: true
  runAsUser: <non-zero uid>
  fsGroup: <non-zero gid>
  seccompProfile:
    type: RuntimeDefault

# Container-level
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

### Why No CPU Limits?

CPU limits in Kubernetes cause CPU throttling — the process is artificially slowed even
when physical CPU is available on the node. This causes latency spikes.

The examples set CPU **requests** (for scheduling) but omit CPU **limits** (to avoid
throttling). Memory limits are always set to prevent OOMKilled cascade failures.

Reference: https://erickhun.com/posts/kubernetes-faster-services-no-cpu-limits/
