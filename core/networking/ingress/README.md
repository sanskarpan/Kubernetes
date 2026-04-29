# Kubernetes Ingress: Complete Reference

## What Is Ingress?

An Ingress is an API object that manages **HTTP and HTTPS routing** from outside the cluster to Services inside the cluster. It provides:

- **Host-based routing:** Route `api.example.com` to one Service and `web.example.com` to another.
- **Path-based routing:** Route `/api/*` to one Service and `/web/*` to another, all on the same hostname.
- **TLS termination:** Accept HTTPS connections, decrypt them at the edge, and forward plain HTTP to pods.
- **Name-based virtual hosting:** Support multiple domains on a single external IP.

### Why Not Just Use LoadBalancer Services?

Each `type: LoadBalancer` Service provisions a separate cloud load balancer, which has real cost implications (hourly charges + data transfer fees). An Ingress Controller acts as a single, shared reverse proxy that fronts ALL your HTTP/HTTPS services through **one** external load balancer. This is dramatically more cost-efficient for clusters with many HTTP services.

### Ingress vs. Gateway API

The Gateway API (`gateway.networking.k8s.io`) is the successor to Ingress, offering more expressive routing, role separation (infrastructure vs. developer), and support for TCP/UDP/gRPC routes. It reached GA in Kubernetes 1.28. For new projects on modern clusters, consider the Gateway API. This directory covers the Ingress API, which remains widely used and production-supported.

---

## Ingress Architecture

```
Internet
    │
    ▼
[ Cloud Load Balancer ]  ◄── One LB, provisioned by LoadBalancer Service
    │                        for the Ingress Controller pods
    ▼
[ Ingress Controller ]   ◄── Deployment (e.g., nginx-ingress-controller)
    │                        Watches Ingress objects; configures nginx/envoy
    │
    ├──► /api  ──► api-service:8080  ──► api pods
    │
    └──► /web  ──► web-service:80    ──► web pods
```

An **Ingress resource** is just a declarative routing rule. It does nothing without an **Ingress Controller** running in the cluster. The Ingress Controller is a pod that watches Ingress objects and configures the underlying proxy (nginx, Envoy, HAProxy, Traefik, etc.).

---

## IngressClass (Required Since Kubernetes 1.18)

Before 1.18, you set the controller via a `kubernetes.io/ingress.class` annotation. Since 1.18, use the `spec.ingressClassName` field and an `IngressClass` resource. This allows multiple Ingress Controllers to coexist in the same cluster (e.g., an internal nginx and an external nginx, or nginx for HTTP and a separate controller for TCP).

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    # Mark this IngressClass as the cluster-wide default.
    # Ingress resources that omit spec.ingressClassName will use this class.
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: k8s.io/ingress-nginx   # Matches the controller's --ingress-class flag
```

Always specify `spec.ingressClassName` in your Ingress resources — do not rely on the default to keep configurations explicit and portable.

---

## Path Types

Every path rule requires a `pathType`:

| pathType | Behaviour |
|---|---|
| `Exact` | Matches the URL path exactly. `/foo` does NOT match `/foo/` or `/foo/bar`. |
| `Prefix` | Matches paths with the given prefix, split by `/`. `/foo` matches `/foo`, `/foo/`, `/foo/bar`. |
| `ImplementationSpecific` | Matching is left to the IngressClass. Behaviour varies by controller. Avoid in portable configs. |

For most API and web routing, use `Prefix`. For health check endpoints or specific static assets, use `Exact`.

---

## Path-Based vs. Host-Based Routing

### Path-Based (Single Hostname, Multiple Services)

```
https://app.example.com/api   →   api-service:8080
https://app.example.com/web   →   web-service:80
```

All traffic arrives on one hostname. The Ingress Controller routes based on the URL path. Simple to manage DNS (one record), but path conflicts must be managed carefully.

### Host-Based (Multiple Hostnames, Multiple Services)

```
https://api.example.com   →   api-service:8080
https://web.example.com   →   web-service:80
```

Each service gets its own subdomain. Cleaner separation. Each hostname needs a DNS record pointing to the Ingress Controller's external IP. In production, a wildcard DNS record (`*.example.com → <ingress-ip>`) covers all subdomains automatically.

You can combine both in a single Ingress resource: multiple hosts, each with multiple paths.

---

## TLS Termination

The Ingress Controller accepts TLS connections on port 443 and decrypts them using a certificate stored in a Kubernetes Secret of type `kubernetes.io/tls`. Traffic between the Ingress Controller pod and the backend Service is plain HTTP by default (encrypted within the cluster network). For end-to-end encryption, configure the backend pod to serve HTTPS and use the appropriate controller annotations.

### Creating a TLS Secret

**Option 1: Self-signed certificate (local dev only)**
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=secure.example.com/O=Dev"

kubectl create secret tls tls-secret \
  --cert=tls.crt \
  --key=tls.key \
  -n networking-demo
```

**Option 2: cert-manager (recommended for production)**
cert-manager is a Kubernetes add-on that automates certificate issuance and renewal from Let's Encrypt, Vault, or a corporate PKI.

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Create a ClusterIssuer for Let's Encrypt
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

Then add to your Ingress:
```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-prod"
```
cert-manager watches the Ingress and automatically creates and renews the TLS secret.

---

## Installing the NGINX Ingress Controller

### Via Helm (Recommended for Production)

```bash
# Add the ingress-nginx Helm repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install into the ingress-nginx namespace
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=128Mi \
  --set controller.metrics.enabled=true \
  --set controller.podAnnotations."prometheus\.io/scrape"=true

# Watch for the LoadBalancer external IP to be assigned
kubectl get svc -n ingress-nginx -w
```

### Via kubectl (Quick Install / Dev)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

# For minikube:
minikube addons enable ingress
```

---

## Common NGINX Ingress Annotations

```yaml
annotations:
  # Rewrite the path before forwarding to the backend.
  # e.g., /api/users becomes /users on the backend.
  nginx.ingress.kubernetes.io/rewrite-target: /$2

  # Force redirect HTTP → HTTPS (301)
  nginx.ingress.kubernetes.io/ssl-redirect: "true"

  # Force HTTPS even for non-TLS Ingresses (redirect all HTTP globally)
  nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

  # Configure a rate limit: 10 requests per second per IP
  nginx.ingress.kubernetes.io/limit-rps: "10"

  # Set the client request body size limit (default: 1m)
  nginx.ingress.kubernetes.io/proxy-body-size: "10m"

  # Set custom proxy timeouts
  nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
  nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "60"

  # Enable CORS
  nginx.ingress.kubernetes.io/enable-cors: "true"
  nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.example.com"

  # Whitelist specific IPs
  nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,203.0.113.5/32"

  # Configure backend protocol (for HTTPS backends)
  nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"

  # Use sticky sessions (consistent hashing on cookie)
  nginx.ingress.kubernetes.io/affinity: "cookie"
  nginx.ingress.kubernetes.io/session-cookie-name: "route"
  nginx.ingress.kubernetes.io/session-cookie-expires: "172800"

  # Configure custom snippet (raw nginx config injection — use with caution)
  nginx.ingress.kubernetes.io/configuration-snippet: |
    more_set_headers "X-Frame-Options: DENY";
    more_set_headers "X-Content-Type-Options: nosniff";
```

---

## Debugging Ingress Issues

```bash
# 1. Verify the Ingress resource was created and has an Address
kubectl get ingress -n networking-demo
# If ADDRESS is empty, the Ingress Controller may not be running or
# ingressClassName does not match.

# 2. Describe the Ingress for events and rule details
kubectl describe ingress path-based -n networking-demo

# 3. Check that the backend Services and their Endpoints exist
kubectl get svc,endpoints -n networking-demo

# 4. Check the Ingress Controller pods are running
kubectl get pods -n ingress-nginx

# 5. View the Ingress Controller logs for 404/502 errors
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=100

# 6. View the generated nginx.conf (inside the controller pod)
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- \
  cat /etc/nginx/nginx.conf | grep -A 5 "server_name"

# 7. Test from inside the cluster (bypassing the LB)
kubectl run debug --image=curlimages/curl --rm -it --restart=Never -- \
  curl -H "Host: api.example.com" http://<ingress-controller-clusterip>/api/health

# 8. Common causes of 502 Bad Gateway:
#    - Backend pod not ready (check readinessProbe)
#    - targetPort mismatch in Service
#    - NetworkPolicy blocking Ingress Controller → pod traffic
#    - Pod is listening on 0.0.0.0 but NetworkPolicy only allows from certain namespaces

# 9. Common causes of 404 from the Ingress Controller (not the backend):
#    - ingressClassName doesn't match the controller
#    - Path type mismatch (Exact vs Prefix)
#    - rewrite-target annotation removing required path prefix
```

---

## Related Files

- `path-based.yml` — Single-host Ingress routing by URL path
- `host-based.yml` — Multi-host Ingress routing by hostname
- `tls.yml` — TLS termination with a certificate Secret
- `../services/` — ClusterIP Services that Ingress backends point to
- `../network-policy/` — NetworkPolicy allowing the Ingress Controller to reach pods
