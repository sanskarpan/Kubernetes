# Multi-Tier Application Example

A complete, namespace-scoped, production-ready multi-tier Kubernetes example.

## Architecture

```
Internet
    |
    v
[ Ingress (nginx) ]
    |           |
    v           v
[Frontend]   [Frontend]   (nginx:1.25-alpine, 2 replicas, HPA 2-10)
    |
    v
[Backend]    [Backend]    (node:18-alpine API, 2 replicas, HPA 2-10)
    |              |
    v              v
[PostgreSQL]   [Redis]    (postgres:16-alpine StatefulSet, redis:7.2-alpine)
```

### Tiers

| Tier | Component | Image | Port | Notes |
|------|-----------|-------|------|-------|
| Frontend | nginx | `nginx:1.25-alpine` | 8080 | Serves static files, proxies /api to backend |
| Backend | Node.js API | `node:18-alpine` | 3000 | REST API |
| Database | PostgreSQL | `postgres:16-alpine` | 5432 | StatefulSet with PVC |
| Cache | Redis | `redis:7.2-alpine` | 6379 | In-memory cache |

### Security

- **Pod Security Admission**: `restricted` enforced on the namespace
- **Network Policies**: default deny-all, explicit allow rules per tier
- **Security Context**: `runAsNonRoot`, `readOnlyRootFilesystem`, `drop ALL capabilities`
- **No service account token auto-mount**

---

## Prerequisites

- Kubernetes >= 1.25 (for Pod Security Admission)
- [ingress-nginx](https://kubernetes.github.io/ingress-nginx/deploy/) installed
- A default StorageClass for PostgreSQL PVC

---

## Deployment Steps

### 1. Apply all manifests

```bash
# From the repo root:
kubectl apply -f examples/multi-tier/namespace.yml

kubectl apply -f examples/multi-tier/frontend/
kubectl apply -f examples/multi-tier/backend/
kubectl apply -f examples/multi-tier/database/
kubectl apply -f examples/multi-tier/cache/

kubectl apply -f examples/multi-tier/network-policy.yml
kubectl apply -f examples/multi-tier/ingress.yml
kubectl apply -f examples/multi-tier/hpa.yml
kubectl apply -f examples/multi-tier/pdb.yml
```

### 2. Create the database secret

```bash
kubectl create secret generic database-secret \
  --namespace=multi-tier \
  --from-literal=postgres-password="$(openssl rand -base64 16)"
```

### 3. Verify everything is running

```bash
kubectl get all -n multi-tier
kubectl get ingress -n multi-tier
kubectl get networkpolicies -n multi-tier
kubectl get pdb -n multi-tier
kubectl get hpa -n multi-tier
```

### 4. Access the application

Add the following to `/etc/hosts` (for local development):
```
<minikube-ip>  multi-tier.example.local
```

Then open: `http://multi-tier.example.local`

For minikube:
```bash
minikube ip
```

For kind (with ingress-nginx):
```bash
kubectl port-forward svc/ingress-nginx-controller 8080:80 -n ingress-nginx
# Then access: http://localhost:8080
```

---

## Cleanup

```bash
kubectl delete namespace multi-tier
# Note: PVCs are not deleted with the namespace by default.
# To also delete data:
kubectl delete pvc -n multi-tier --all
```

---

## Customization

| What to change | File |
|---------------|------|
| Number of frontend/backend replicas | `frontend/deployment.yml`, `backend/deployment.yml` |
| HPA min/max replicas | `hpa.yml` |
| Database size | `database/statefulset.yml` → `volumeClaimTemplates` |
| Ingress hostname | `ingress.yml` |
| Network policies | `network-policy.yml` |
