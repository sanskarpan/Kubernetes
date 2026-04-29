# EasyShop on KIND — Complete Deployment Guide

EasyShop is a multi-tier e-commerce application demonstrating a production-style Kubernetes setup on a local KIND cluster. It covers:

- StatefulSet (MongoDB)
- Deployment (Node.js app)
- PersistentVolume + PersistentVolumeClaim
- NGINX Ingress Controller
- Kubernetes Jobs (database migration)
- Multi-namespace layout

## Architecture

```
Internet
    │
    ▼
NGINX Ingress Controller (NodePort 80/443 → KIND host port 8080/8443)
    │
    ├── / → EasyShop Service (ClusterIP:3000)
    │              │
    │              ▼
    │       EasyShop Deployment (2 replicas)
    │              │
    │              ▼
    └── MongoDB StatefulSet (ClusterIP:27017)
                   │
                   ▼
            PersistentVolumeClaim (10Gi)
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Docker | 24+ | https://docs.docker.com/get-docker/ |
| KIND | 0.29+ | `setup/local/kind/install.sh` |
| kubectl | 1.32+ | included in `install.sh` |
| helm | 3.17+ | `helm/get_helm.sh` |

## Step 1 — Create the KIND Cluster

```bash
# From repo root
make cluster-up

# Or manually with port mappings for Ingress
kind create cluster --name kube-platform --config setup/local/kind/kind-config.yml
```

## Step 2 — Install NGINX Ingress Controller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for the ingress controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

## Step 3 — Create Namespace

```bash
kubectl create namespace easyshop
kubectl label namespace easyshop \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted
```

## Step 4 — Deploy MongoDB (StatefulSet)

```bash
# Create ConfigMap and Secret first
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-config
  namespace: easyshop
data:
  MONGO_INITDB_DATABASE: easyshop
---
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-secret
  namespace: easyshop
type: Opaque
stringData:
  # CHANGE THESE — use SealedSecrets or ESO in production
  MONGO_INITDB_ROOT_USERNAME: admin
  MONGO_INITDB_ROOT_PASSWORD: changeme
EOF

# Deploy MongoDB StatefulSet
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: easyshop
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: easyshop
spec:
  serviceName: mongodb
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: mongodb
          image: mongo:7.0
          ports:
            - containerPort: 27017
          envFrom:
            - configMapRef:
                name: mongodb-config
            - secretRef:
                name: mongodb-secret
          resources:
            requests:
              memory: "256Mi"
              cpu: "200m"
            limits:
              memory: "512Mi"
          volumeMounts:
            - name: data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
EOF
```

## Step 5 — Deploy EasyShop Application

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: easyshop
  namespace: easyshop
spec:
  replicas: 2
  selector:
    matchLabels:
      app: easyshop
  template:
    metadata:
      labels:
        app: easyshop
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: easyshop
          image: amitabhdevops/online_shop:latest
          ports:
            - containerPort: 3000
          env:
            - name: MONGODB_URI
              value: "mongodb://admin:changeme@mongodb.easyshop.svc.cluster.local:27017/easyshop"
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
---
apiVersion: v1
kind: Service
metadata:
  name: easyshop
  namespace: easyshop
spec:
  selector:
    app: easyshop
  ports:
    - port: 3000
      targetPort: 3000
EOF
```

## Step 6 — Create Ingress

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: easyshop-ingress
  namespace: easyshop
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: easyshop.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: easyshop
                port:
                  number: 3000
EOF

# Add to /etc/hosts (macOS/Linux)
echo "127.0.0.1 easyshop.local" | sudo tee -a /etc/hosts
```

## Step 7 — Access the Application

```bash
# KIND maps containerPort 80 -> hostPort 8080 (see kind-config.yml)
curl http://easyshop.local:8080

# Or open in browser:
open http://easyshop.local:8080
```

## Verification Commands

```bash
# Check all resources
kubectl get all -n easyshop

# Check MongoDB data persists (write something, delete pod, verify)
kubectl exec -it mongodb-0 -n easyshop -- mongosh -u admin -p changeme
> use easyshop; db.test.insert({hello: "world"})
kubectl delete pod mongodb-0 -n easyshop
# Wait for pod to restart, then verify data:
kubectl exec -it mongodb-0 -n easyshop -- mongosh -u admin -p changeme
> use easyshop; db.test.find()

# Check Ingress
kubectl describe ingress easyshop-ingress -n easyshop
```

## Cleanup

```bash
kubectl delete namespace easyshop
make cluster-down
```

## What This Demonstrates

| Concept | Where |
|---|---|
| StatefulSet with PVC | MongoDB deployment |
| Headless Service | mongodb service (clusterIP: None) |
| Multi-replica Deployment | EasyShop (2 replicas) |
| Ingress with host-based routing | easyshop-ingress |
| ConfigMap for app config | mongodb-config |
| Secret for credentials | mongodb-secret |
| Health probes | EasyShop readiness/liveness |
| KIND port mapping | kind-config.yml |
