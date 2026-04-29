# Intro — Core Kubernetes Objects

This example introduces the three foundational Kubernetes objects:
**Pod**, **Deployment**, and **Service**.

---

## What Each File Does

### `pod.yml` — The Minimal Unit

A Pod is a wrapper around one or more containers. This file creates a single nginx Pod.

**Why you should never use bare Pods in production:**
- If the Pod crashes, it is NOT automatically restarted (unlike a Deployment)
- If the node the Pod runs on fails, the Pod is lost permanently
- You cannot scale, update, or roll back bare Pods

Use this to understand what a Pod is. In practice, always use a Deployment.

### `deployment.yml` — Self-Healing, Scalable Pods

A Deployment manages a ReplicaSet, which manages Pods. When a Pod crashes, the ReplicaSet
controller creates a new one. When you update the Deployment spec, the rolling update
controller replaces old Pods with new ones without downtime.

Key Deployment fields explained:
- `replicas: 1` — always maintain 1 running Pod
- `selector.matchLabels` — the Deployment "owns" Pods with these labels (immutable)
- `template` — the blueprint for every Pod this Deployment creates

### `service.yml` — Stable Network Endpoint

Pods get new IP addresses every time they restart. A Service gives you a stable DNS name
and virtual IP that always routes to healthy Pods.

This Service uses `NodePort` to expose nginx on port `30080` of every node in the cluster.
This is the simplest way to access the app from outside the cluster during development.

---

## Step-by-Step Guide

### 1. Apply all files

```bash
kubectl apply -f examples/nginx-reference/01-intro/
```

Expected output:
```
pod/nginx-pod created
deployment.apps/nginx-deployment created
service/nginx-service created
```

### 2. Verify the Pod is Running

```bash
kubectl get pods
```

Both the bare Pod and the Deployment's Pod should be Running:
```
NAME                                READY   STATUS    RESTARTS   AGE
nginx-pod                           1/1     Running   0          10s
nginx-deployment-6d84b876b5-abc12   1/1     Running   0          10s
```

### 3. Check the Deployment

```bash
kubectl get deployment nginx-deployment
kubectl describe deployment nginx-deployment
```

### 4. Access the Application

**Using minikube:**
```bash
minikube service nginx-service
```

**Using port-forward (works with any cluster):**
```bash
kubectl port-forward svc/nginx-service 8080:80
# Open http://localhost:8080
```

**Direct NodePort (if you know your node IP):**
```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
curl http://${NODE_IP}:30080
```

### 5. Scale the Deployment

```bash
# Scale to 3 replicas
kubectl scale deployment nginx-deployment --replicas=3

# Watch the new pods come up
kubectl get pods -w
```

### 6. Simulate a Pod Crash

```bash
# Delete one of the Deployment's Pods
POD=$(kubectl get pods -l app.kubernetes.io/name=nginx -o name | head -1)
kubectl delete ${POD}

# Watch the ReplicaSet immediately create a replacement
kubectl get pods -w
```

Notice that the Deployment's Pod is immediately replaced. The bare Pod (`nginx-pod`)
would NOT be replaced.

### 7. Rolling Update

```bash
# Update the image version
kubectl set image deployment/nginx-deployment nginx=nginx:1.27.1

# Watch the rolling update
kubectl rollout status deployment/nginx-deployment

# View the rollout history
kubectl rollout history deployment/nginx-deployment

# Roll back to the previous version
kubectl rollout undo deployment/nginx-deployment
```

### 8. Clean Up

```bash
kubectl delete -f examples/nginx-reference/01-intro/
```

---

## Key Concepts Summary

| Concept         | What It Does                                          | Production Use?   |
|-----------------|-------------------------------------------------------|-------------------|
| Pod             | Runs one or more containers                           | Never bare        |
| ReplicaSet      | Maintains a desired number of Pod replicas            | Never directly    |
| Deployment      | Manages ReplicaSets; handles updates and rollbacks    | Always            |
| Service         | Stable network endpoint routing to Pods               | Always            |
| NodePort        | Exposes Service on each node's IP                     | Dev/testing       |
| ClusterIP       | Internal Service (use with Ingress for HTTP)          | Production        |

---

## Next Step

Proceed to [`02-production-baseline/`](../02-production-baseline/README.md) to add:
- Security contexts
- Resource limits
- Health probes
- PodDisruptionBudget
- NetworkPolicy
- HorizontalPodAutoscaler
