# Kubernetes NetworkPolicy: Complete Reference

## What Is a NetworkPolicy?

A NetworkPolicy is a Kubernetes API resource that specifies how pods are allowed to communicate with each other and with external endpoints. It is enforced by the cluster's CNI (Container Network Interface) plugin, not by kube-proxy or the API server. Without a supported CNI plugin, NetworkPolicy resources are created and stored in etcd but have **no effect**.

**CNI plugins that support NetworkPolicy:**
- Calico (most feature-rich)
- Cilium (eBPF-based, also supports host-level and L7 policies)
- Weave Net
- Antrea
- Canal (Calico policies + Flannel networking)

**CNI plugins that do NOT support NetworkPolicy:**
- Flannel (alone) — policies are stored but silently ignored
- AWS VPC CNI (alone) — requires Calico for policy enforcement on EKS

Verify your CNI supports NetworkPolicy:
```bash
kubectl get pods -n kube-system | grep -E "calico|cilium|weave|antrea"
```

---

## Default Allow-All Behavior

**CRITICAL:** By default, a namespace with no NetworkPolicy objects allows ALL traffic — pod to pod, namespace to namespace, and external to pod. Any pod can reach any other pod on any port.

This is the biggest surprise for teams moving from traditional firewall models. In a default Kubernetes cluster:
- A compromised pod in the `development` namespace can make TCP connections to MySQL in the `production` namespace on port 3306.
- A compromised pod can reach the cloud metadata API at `169.254.169.254` and steal the node's IAM role credentials.
- A compromised pod can port-scan the entire cluster network.

**The solution:** Apply a default-deny NetworkPolicy to every namespace, then add specific allow rules. This is the network equivalent of "deny all, allow by exception."

---

## Policy Types

A NetworkPolicy specifies `policyTypes` which determines what kind of traffic the policy applies to:

### Ingress
Controls traffic coming **into** pods that match `spec.podSelector`. If a pod has any NetworkPolicy with `Ingress` in `policyTypes`, only connections explicitly allowed by an ingress rule in any matching policy are permitted. All other inbound connections are dropped.

### Egress
Controls traffic going **out of** pods that match `spec.podSelector`. Same logic: once any policy with `Egress` is applied to a pod, only explicitly allowed outbound connections are permitted.

### Specifying Both
```yaml
policyTypes:
  - Ingress
  - Egress
```
When both are specified, the pod is isolated in both directions unless explicit rules allow traffic.

### What Counts as "Isolation"?
A pod is considered **isolated for ingress** if there is at least one NetworkPolicy in its namespace whose `podSelector` matches it and whose `policyTypes` includes `Ingress`. Ditto for egress. Multiple policies are unioned — a connection is allowed if ANY matching policy permits it.

---

## Selector Types

### podSelector
Selects pods by label. Used in:
- `spec.podSelector` — identifies which pods this policy applies TO (the "subject").
- `spec.ingress[].from[].podSelector` — identifies which pods are ALLOWED to send traffic.
- `spec.egress[].to[].podSelector` — identifies which pods are ALLOWED to receive traffic.

An empty `podSelector: {}` matches ALL pods in the namespace.

```yaml
podSelector:
  matchLabels:
    app.kubernetes.io/name: mysql   # Only applies to mysql pods
```

### namespaceSelector
Selects namespaces by label. Traffic from/to pods in matching namespaces is allowed.

```yaml
namespaceSelector:
  matchLabels:
    environment: production   # Namespace must have this label
```

Add a label to a namespace:
```bash
kubectl label namespace production environment=production
```

### Combining podSelector and namespaceSelector
When both are specified in the same `from` or `to` entry (as a single list item), they are ANDed. Both conditions must be true:
```yaml
from:
  - namespaceSelector:
      matchLabels:
        environment: production   # AND
    podSelector:
      matchLabels:
        role: frontend            # Must be in a production namespace AND be a frontend pod
```

When they are in separate list items, they are ORed:
```yaml
from:
  - namespaceSelector:
      matchLabels:
        environment: production   # OR
  - podSelector:
      matchLabels:
        role: frontend            # ...be a frontend pod in the same namespace
```

This AND/OR distinction is a very common source of bugs. Check carefully.

### ipBlock
Selects traffic by IP CIDR range. Used for allowing/blocking external IPs.

```yaml
from:
  - ipBlock:
      cidr: 10.0.0.0/8        # Allow from the entire internal network
      except:
        - 10.1.0.0/16         # Except this subnet
```

---

## The Deny-All + Allow-List Pattern (Production Standard)

**Step 1:** Apply `default-deny-all` to the namespace (denies all ingress and egress).

**Step 2:** Add specific allow policies for each communication path you need:
- Allow ingress from the Ingress Controller namespace.
- Allow ingress from monitoring (Prometheus scraping).
- Allow egress to DNS (port 53, both UDP and TCP).
- Allow egress to specific downstream services.

This ensures that any newly deployed pod is automatically isolated until a policy explicitly permits its traffic. Forgetting to write a NetworkPolicy means the communication fails visibly, which is far preferable to silent over-permissiveness.

---

## Common Production Patterns

### 1. Allow the Ingress Controller to reach pods

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-controller
  namespace: workloads
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: web
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
          protocol: TCP
```

### 2. Allow Prometheus to scrape metrics

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: workloads
spec:
  podSelector: {}          # All pods in namespace
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - port: 9090
          protocol: TCP
```

### 3. Allow egress to DNS (always required)

When you deny all egress, DNS stops working immediately and pods cannot resolve any hostnames. Always include this in your egress policies:

```yaml
egress:
  - to:
      - namespaceSelector: {}  # Any namespace (kube-dns is in kube-system)
    ports:
      - port: 53
        protocol: UDP
      - port: 53
        protocol: TCP  # DNS falls back to TCP for large responses (DNSSEC)
```

---

## Blocking the Cloud Metadata API (169.254.169.254)

This is a **critical security control** in cloud environments. The instance metadata API at `169.254.169.254` is a link-local IP accessible from every instance (pod). It provides:
- IAM role credentials for the node (EC2 instance profile, GCP service account, Azure managed identity)
- User data (often contains bootstrap secrets)
- Instance identity documents

A compromised pod can call `http://169.254.169.254/latest/meta-data/iam/security-credentials/<role-name>` and receive temporary AWS credentials with the full permissions of the node's IAM role. This is a well-known privilege escalation technique (e.g., the 2019 Capital One breach exploited SSRF to reach the EC2 metadata API).

**Protection layers:**
1. Use IMDSv2 (token-required) on EC2 — mitigates SSRF that cannot set custom HTTP headers.
2. Apply `block-cloud-metadata` NetworkPolicy — blocks at the Kubernetes network layer regardless of IMDSv2 configuration.
3. Apply least-privilege IAM roles to nodes — minimize blast radius if credentials are stolen.

See `block-metadata-api.yml` for the NetworkPolicy implementation.

---

## Testing NetworkPolicies

```bash
# Test that a connection IS allowed (should succeed):
kubectl exec -n workloads deploy/frontend -- \
  curl -s --max-time 5 http://api-service.workloads.svc.cluster.local:8080/health

# Test that a connection IS blocked (should time out or be refused):
kubectl exec -n workloads deploy/frontend -- \
  curl -s --max-time 5 http://mysql.database.svc.cluster.local:3306
# Expected: connection refused or timeout (NOT a successful connection)

# Test metadata API is blocked:
kubectl exec -n workloads deploy/frontend -- \
  curl -s --max-time 5 http://169.254.169.254/latest/meta-data/
# Expected: timeout (connection blocked by NetworkPolicy)

# Test DNS still works (after applying deny-all + allow-DNS egress):
kubectl exec -n workloads deploy/frontend -- \
  nslookup kubernetes.default.svc.cluster.local

# Use netshoot for comprehensive network debugging:
kubectl run netshoot --image=nicolaka/netshoot --rm -it -n workloads --restart=Never -- bash
# Inside: curl, dig, nmap, tcpdump, ss, iperf3 all available
```

---

## Related Files

- `deny-all-ingress.yml` — Default deny-all NetworkPolicy (apply first in every namespace)
- `allow-same-namespace.yml` — Allow intra-namespace pod communication
- `mysql-isolation.yml` — Realistic production policy for MySQL (ingress from app, egress DNS only)
- `block-metadata-api.yml` — Block the cloud metadata API (security critical)
