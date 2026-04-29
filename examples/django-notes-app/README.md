# Django Notes App — Full Kubernetes Deployment

A real-world Django web application deployed to Kubernetes with production-grade
manifests, multi-stage Dockerfile, Ingress, HPA, and ArgoCD GitOps integration.

---

## What Is This App?

The Django Notes App is a simple note-taking web application built with:
- **Backend:** Django 4.x (Python)
- **Database:** SQLite (for demo; use PostgreSQL in production)
- **Web Server:** Django's built-in `runserver` (for demo; use Gunicorn + nginx in production)

**Source:** https://github.com/LondheShubham153/django-notes-app

---

## Architecture

```
                        Internet
                           │
                           ▼
                    ┌─────────────┐
                    │   Ingress   │  nginx ingress controller
                    │  Controller │  notes.example.local → notes-app:80
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   Service   │  ClusterIP, port 80
                    │  notes-app  │  → targetPort 8000
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
       ┌──────▼──────┐    ...    ┌──────▼──────┐
       │    Pod 1    │           │    Pod N    │
       │  notes-app  │           │  notes-app  │
       │  :8000      │           │  :8000      │
       └─────────────┘           └─────────────┘
              ▲
              │ scales
       ┌──────┴──────┐
       │     HPA     │  CPU > 70% → add pods
       └─────────────┘
```

---

## Building the Image Locally

### Multi-Stage Build

The Dockerfile uses two stages:
1. **builder** — installs Python dependencies into `/install` (with build tools)
2. **runtime** — copies only the installed packages (no build tools, smaller image)

```bash
# Build the image
cd examples/django-notes-app
docker build -t notes-app:local .

# Verify the image runs
docker run --rm -p 8000:8000 notes-app:local

# Open http://localhost:8000
```

### Build for Production (with digest pinning)

```bash
# Build and push
docker build -t myrepo/notes-app:${GIT_SHA} .
docker push myrepo/notes-app:${GIT_SHA}

# Get the digest for pinning in values.yaml
docker inspect --format='{{index .RepoDigests 0}}' myrepo/notes-app:${GIT_SHA}
```

---

## Deploying to Kubernetes

### Prerequisites

```bash
# Start local cluster
minikube start --cpus=4 --memory=4g

# Enable Ingress controller
minikube addons enable ingress

# Enable metrics server (for HPA)
minikube addons enable metrics-server
```

### Deploy Step by Step

```bash
# 1. Create the namespace
kubectl apply -f examples/django-notes-app/k8s/namespace.yml

# 2. Deploy the application
kubectl apply -f examples/django-notes-app/k8s/deployment.yml

# 3. Create the Service
kubectl apply -f examples/django-notes-app/k8s/service.yml

# 4. Create the PodDisruptionBudget
kubectl apply -f examples/django-notes-app/k8s/pdb.yml

# 5. Create the HPA
kubectl apply -f examples/django-notes-app/k8s/hpa.yml

# 6. Create the Ingress
kubectl apply -f examples/django-notes-app/k8s/ingress.yml

# Or apply everything at once
kubectl apply -f examples/django-notes-app/k8s/
```

### Verify the Deployment

```bash
# Check pod status
kubectl get pods -n notes-app -w

# Check all resources
kubectl get all -n notes-app

# Check the HPA
kubectl get hpa -n notes-app

# Check the Ingress
kubectl get ingress -n notes-app
```

### Access the Application

**Via port-forward (any cluster):**
```bash
kubectl port-forward svc/notes-app -n notes-app 8080:80
# Open http://localhost:8080
```

**Via Ingress (minikube):**
```bash
# Add to /etc/hosts
echo "$(minikube ip) notes.example.local" | sudo tee -a /etc/hosts

# Open https://notes.example.local
```

### Run Migrations (First Deploy)

```bash
# Exec into a pod and run Django migrations
POD=$(kubectl get pods -n notes-app -o name | head -1)
kubectl exec -n notes-app ${POD} -- python manage.py migrate

# Create a superuser (optional)
kubectl exec -it -n notes-app ${POD} -- python manage.py createsuperuser
```

---

## ArgoCD Integration

### Create an ArgoCD Application for Notes App

```yaml
# gitops/argocd/apps/notes-app.yml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: notes-app
  namespace: argocd
spec:
  project: kube-platform
  source:
    repoURL: https://github.com/your-org/your-kubernetes-repo.git
    targetRevision: main
    path: examples/django-notes-app/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: notes-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f gitops/argocd/apps/notes-app.yml -n argocd
```

After applying, ArgoCD will:
1. Detect the new Application
2. Sync the manifests from Git to the cluster
3. Continuously monitor for drift and heal it

### View in ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Login: admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
```

---

## Production Considerations

### Database

This demo uses SQLite (file-based database). For production:
1. Use **PostgreSQL** (or a managed database like AWS RDS, Cloud SQL)
2. Configure Django to use `psycopg2` and `DATABASE_URL` from a Secret
3. Never run database migration as part of the container startup — use an init container or Job

### Secrets Management

```yaml
# Use Kubernetes Secrets (base64-encoded, not encrypted by default)
# For production, use External Secrets Operator + AWS Secrets Manager / Vault
apiVersion: v1
kind: Secret
metadata:
  name: django-secrets
  namespace: notes-app
type: Opaque
stringData:
  DJANGO_SECRET_KEY: "your-secret-key"
  DATABASE_URL: "postgresql://user:password@postgres:5432/notesdb"
```

### Static Files

Django's `runserver` serves static files. For production, serve static files from:
- nginx sidecar container (reading from a shared emptyDir)
- Cloud storage (AWS S3 with `django-storages`)
- CDN (CloudFront, Fastly)

### TLS

Update `k8s/ingress.yml` to use a real TLS certificate:
```yaml
# Use cert-manager with Let's Encrypt
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - secretName: notes-app-tls
      hosts:
        - notes.yourdomain.com
```

---

## Clean Up

```bash
kubectl delete -f examples/django-notes-app/k8s/
kubectl delete namespace notes-app
```
