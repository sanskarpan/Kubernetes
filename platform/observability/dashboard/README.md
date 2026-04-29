# Kubernetes Dashboard

## Overview

The Kubernetes Dashboard is a web-based UI for managing and monitoring cluster resources. It provides a visual interface for viewing workload status, logs, and resource consumption, and for basic resource management tasks.

---

## Installation via Helm

```bash
helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
helm repo update

helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard \
  --create-namespace

# Verify the deployment is ready
kubectl get pods -n kubernetes-dashboard
```

---

## IMPORTANT WARNING: admin-user with cluster-admin is Development Only

> **SECURITY WARNING**
>
> The admin-user ServiceAccount pattern (creating a ServiceAccount and binding it to `cluster-admin`) gives **unrestricted, unauthenticated access to every resource in the cluster** via the Dashboard token.
>
> This is appropriate ONLY for:
> - Local development clusters (minikube, kind, k3d)
> - Throwaway demo clusters
> - Personal learning environments
>
> **NEVER use this pattern in:**
> - Shared development environments
> - Staging clusters
> - Any production cluster
> - Any cluster accessible from the internet

The risk is that anyone who obtains the Dashboard token (which is a long-lived bearer token by default) has `cluster-admin` access. There is no authentication between the token holder and the API server — the token IS the credential.

---

## Production Alternative: OIDC Integration

For production clusters, configure the Dashboard to use your organization's identity provider via OIDC:

```bash
helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard \
  --set "extraArgs[0]=--authentication-mode=token" \
  --set "extraArgs[1]=--oidc-issuer-url=https://accounts.google.com" \
  --set "extraArgs[2]=--oidc-client-id=your-client-id" \
  --set "extraArgs[3]=--oidc-username-claim=email" \
  --set "extraArgs[4]=--oidc-groups-claim=groups"
```

With OIDC:
- Users authenticate with your existing SSO (Google, Okta, GitHub, Azure AD)
- Kubernetes RBAC applies based on the user's groups
- No long-lived tokens — OIDC tokens expire (typically 1 hour)
- Audit logs capture individual user actions

### Recommended OIDC providers

- **Dex** — lightweight OIDC proxy for Kubernetes (can front LDAP, GitHub, SAML)
- **Okta** — enterprise SSO with Kubernetes integration
- **Google Workspace** — built-in OIDC with `accounts.google.com` as issuer
- **Azure AD** — use with the `oidc-login` kubectl plugin for seamless login

---

## Port-Forward Access (Development)

For local development, access the Dashboard via port-forwarding — this avoids exposing the Dashboard via an Ingress or LoadBalancer:

```bash
# Forward the Dashboard service to localhost
kubectl port-forward -n kubernetes-dashboard \
  service/kubernetes-dashboard-kong-proxy 8443:443

# Access at: https://localhost:8443
# Accept the self-signed certificate warning in your browser
```

Do not expose the Dashboard via a public Ingress. If an Ingress is required, protect it with:
- mTLS client certificates
- OAuth2 Proxy in front of the Dashboard
- IP allowlist

---

## Creating Tokens for Login

### Temporary token (recommended for development)

```bash
# Create a short-lived token for the admin-user ServiceAccount
kubectl create token admin-user -n kubernetes-dashboard --duration=1h
```

Copy the output token. Paste it into the Dashboard login screen under "Token".

The token expires after 1 hour. Create a new one when needed.

### Long-lived token (not recommended)

```bash
# Create a long-lived token Secret (indefinite expiry — avoid in production)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF

# Retrieve the token
kubectl get secret admin-user-token -n kubernetes-dashboard \
  -o jsonpath='{.data.token}' | base64 -d
```

Long-lived tokens have no expiry — they remain valid until the Secret is deleted. Avoid these in any environment where security matters.

---

## Dashboard Features

The Dashboard provides visibility into:

| Category | What you can see/do |
|----------|-------------------|
| Workloads | Deployments, StatefulSets, DaemonSets, Jobs, CronJobs, Pods |
| Services | Services, Ingresses, Endpoints |
| Config | ConfigMaps, Secrets (obfuscated) |
| Storage | PersistentVolumeClaims, PersistentVolumes, StorageClasses |
| RBAC | Roles, ClusterRoles, Bindings |
| Nodes | Node status, capacity, conditions |
| Namespaces | Namespace overview, resource usage |

For production observability, prefer Grafana dashboards (kube-state-metrics, node-exporter) over the Kubernetes Dashboard — Grafana provides historical data and alerting that the Dashboard doesn't offer.
