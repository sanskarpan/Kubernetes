# Online Shop on KIND — Deployment Guide

A single-service online shop application demonstrating:
- Building a Docker image locally and loading into KIND
- NGINX Ingress Controller setup
- ConfigMap for application configuration
- Deployment + Service + Ingress pattern

## Architecture

```
Browser
   │
   ▼
KIND host port 8080
   │
   ▼
NGINX Ingress Controller
   │
   ▼
online-shop Service (ClusterIP:3000)
   │
   ▼
online-shop Deployment (2 replicas)
```

## Prerequisites

```bash
# Create KIND cluster
make cluster-up

# Install NGINX Ingress Controller for KIND
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

## Option A — Use Pre-built Image (Quick Start)

```bash
kubectl create namespace online-shop

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: online-shop
  namespace: online-shop
  labels:
    app.kubernetes.io/name: online-shop
    app.kubernetes.io/part-of: kube-platform
spec:
  replicas: 2
  selector:
    matchLabels:
      app: online-shop
  template:
    metadata:
      labels:
        app: online-shop
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: online-shop
          image: amitabhdevops/online_shop:latest
          ports:
            - containerPort: 3000
          resources:
            requests:
              memory: "256Mi"
              cpu: "200m"
            limits:
              memory: "512Mi"
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 15
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]
---
apiVersion: v1
kind: Service
metadata:
  name: online-shop
  namespace: online-shop
spec:
  selector:
    app: online-shop
  ports:
    - port: 3000
      targetPort: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: online-shop-ingress
  namespace: online-shop
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: shop.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: online-shop
                port:
                  number: 3000
EOF

# Add to /etc/hosts
echo "127.0.0.1 shop.local" | sudo tee -a /etc/hosts

# Access the shop
open http://shop.local:8080
```

## Option B — Build Image Locally and Load into KIND

KIND clusters do not have access to the internet by default (registry pull still works, but this shows the local image workflow).

```bash
# Clone or create your Dockerfile
# Build the image locally
docker build -t online-shop:local .

# Load into KIND cluster (avoids registry push/pull)
kind load docker-image online-shop:local --name kube-platform

# Verify image is available in the cluster
docker exec kube-platform-control-plane crictl images | grep online-shop
```

Then use `image: online-shop:local` and `imagePullPolicy: Never` in the Deployment.

## Deployment Strategies Comparison

This project is ideal for testing all 4 deployment strategies:

```bash
# Apply deployment strategies from this repo
kubectl apply -f core/workloads/deployment-strategies/rolling-update/

# Simulate a version change
kubectl set image deployment/rolling-update-demo \
  online-shop=amitabhdevops/online_shop_without_footer:latest \
  -n rolling-ns

# Watch the rollout
kubectl rollout status deployment/rolling-update-demo -n rolling-ns

# Rollback if needed
kubectl rollout undo deployment/rolling-update-demo -n rolling-ns
```

## Verification

```bash
# All pods running
kubectl get pods -n online-shop

# Ingress configured
kubectl describe ingress online-shop-ingress -n online-shop

# End-to-end test
curl -H "Host: shop.local" http://localhost:8080

# Check HPA (if metrics-server installed)
kubectl top pods -n online-shop
```

## What This Demonstrates

| Concept | Where |
|---|---|
| Deployment + Service + Ingress | Core pattern |
| Host-based Ingress routing | online-shop-ingress |
| Local image loading | `kind load docker-image` |
| Health probes | readiness + liveness |
| Graceful shutdown | preStop hook |
| Resource requests/limits | containers.resources |
| Rolling updates | `kubectl set image` |
