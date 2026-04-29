# cert-manager Example

This example demonstrates how to use [cert-manager](https://cert-manager.io/) to automatically provision and renew TLS certificates from Let's Encrypt.

---

## Architecture

```
Browser
  |  (HTTPS)
  v
[ Ingress (nginx) ] ← TLS termination with cert-manager cert
  |
  v
[ Your App Service ]
```

cert-manager watches Ingress resources annotated with `cert-manager.io/cluster-issuer`. When it finds one, it:
1. Creates an ACME challenge (HTTP-01) to prove domain ownership.
2. Requests a certificate from Let's Encrypt.
3. Stores the certificate in a Kubernetes Secret (TLS type).
4. Automatically renews the certificate ~30 days before expiry.

---

## Prerequisites

- Kubernetes >= 1.25
- Helm >= 3.14
- ingress-nginx installed and accessible from the internet
- A domain name with DNS pointing to your cluster's ingress IP

---

## Installation

### 1. Install cert-manager with Helm

```bash
# Add the jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager with CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.2 \
  --set crds.enabled=true

# Verify installation
kubectl get pods -n cert-manager
```

### 2. Create the ClusterIssuers

```bash
# Edit cluster-issuer.yml to replace admin@example.com with your email address
kubectl apply -f examples/cert-manager/cluster-issuer.yml

# Verify the issuers are ready
kubectl get clusterissuer
```

Expected output:
```
NAME                   READY   AGE
letsencrypt-prod       True    30s
letsencrypt-staging    True    30s
```

### 3. Apply the Ingress with TLS

```bash
# Edit ingress-with-cert.yml to set your actual hostname and service name
kubectl apply -f examples/cert-manager/ingress-with-cert.yml
```

### 4. Verify certificate issuance

```bash
# Watch the Certificate resource (created automatically by cert-manager)
kubectl get certificate -n web --watch

# Check the Certificate details
kubectl describe certificate app-example-com-tls -n web

# Check the CertificateRequest
kubectl get certificaterequest -n web

# Check the ACME Order and Challenge
kubectl get order -n web
kubectl get challenge -n web
```

---

## Troubleshooting

### Certificate stuck in "False/Pending"

```bash
# Check the certificate status
kubectl describe certificate <cert-name> -n <namespace>

# Check the ClusterIssuer status
kubectl describe clusterissuer letsencrypt-prod

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager --tail=100
```

Common causes:
- DNS not resolving to the ingress IP
- Ingress controller not reachable from the internet (port 80 must be open for HTTP-01)
- Rate limit hit (use staging issuer first)

### Test with staging issuer first

Always test with `letsencrypt-staging` before switching to `letsencrypt-prod`. The staging issuer has much more permissive rate limits but issues untrusted certificates (browsers will show a warning, which is fine for testing).

```bash
# Switch the annotation to staging:
# cert-manager.io/cluster-issuer: letsencrypt-staging

# After verifying, delete the staging cert and switch to prod:
kubectl delete certificate app-example-com-tls -n web
# Update the annotation to: cert-manager.io/cluster-issuer: letsencrypt-prod
kubectl apply -f examples/cert-manager/ingress-with-cert.yml
```

---

## Useful Commands

```bash
# List all managed certificates cluster-wide
kubectl get certificate --all-namespaces

# Check certificate expiry
kubectl get certificate -n web -o jsonpath='{.items[*].status.notAfter}'

# Manually trigger certificate renewal (usually not needed — cert-manager auto-renews)
kubectl annotate certificate app-example-com-tls \
  cert-manager.io/issuer-name=letsencrypt-prod \
  --overwrite -n web

# Uninstall cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
```
