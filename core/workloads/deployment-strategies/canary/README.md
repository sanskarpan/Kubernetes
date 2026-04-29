# Canary Deployment Strategy

## What Is It?

A canary deployment routes a **small percentage of production traffic** to a new version of the application while the majority of traffic continues to go to the stable version. The name comes from the "canary in a coal mine" — a small indicator that detects problems before they affect everyone.

If the canary version shows elevated error rates, increased latency, or unexpected behavior, it is rolled back. If metrics look good, the canary is gradually promoted to handle all traffic.

---

## How Traffic Split Works (Kubernetes-Native)

Kubernetes does not have native traffic weighting by percentage. Instead, canary in "plain Kubernetes" relies on **replica ratio**.

The Service selects pods from both the stable and canary deployments (using a shared label). Traffic is distributed proportionally to the number of Ready pods.

```
Stable:  4 replicas  →  4/(4+1) = 80% of traffic
Canary:  1 replica   →  1/(4+1) = 20% of traffic
```

To adjust the traffic split:
- Increase canary replicas to send more traffic to canary.
- Decrease stable replicas (while adding canary replicas) to shift traffic progressively.

**Limitations of replica-based splitting:**
- Minimum granularity is 1 replica = 1/(total replicas). With 4 stable + 1 canary, minimum canary traffic is 20%.
- Cannot route specific users or requests to canary (it's random load balancing).
- Cannot do sub-5% canary without many total replicas.

For fine-grained control, use the **Ingress-based approach** (see `ingress.yml`) or a **service mesh**.

---

## Ingress-Based Traffic Splitting (NGINX Ingress)

The NGINX Ingress Controller supports canary annotations for precise traffic control:

```yaml
annotations:
  nginx.ingress.kubernetes.io/canary: "true"
  nginx.ingress.kubernetes.io/canary-weight: "5"   # Exactly 5% to canary
```

This is independent of replica count — you can send 5% of traffic to 1 canary pod without changing anything else. See `ingress.yml` for the full example.

---

## Service Mesh Traffic Splitting (Istio)

With Istio's VirtualService, you get exact percentage routing:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
spec:
  http:
  - route:
    - destination:
        host: myapp
        subset: stable
      weight: 95
    - destination:
        host: myapp
        subset: canary
      weight: 5
```

Service meshes also enable:
- **Header-based routing:** Route requests with `X-Beta-User: true` header to canary.
- **Cookie-based routing:** Sticky sessions to canary for specific users.
- **Shadow mirroring:** Copy 100% of traffic to canary without serving responses from it (risk-free testing).

---

## Promotion Procedure

```bash
# Step 1: Start with small canary (1 replica = 20% with 4 stable)
kubectl apply -f stable-deployment.yml
kubectl apply -f canary-deployment.yml

# Step 2: Observe metrics for 30-60 minutes
# - Error rate in canary vs stable
# - P99 latency in canary vs stable
# - Business metrics (conversion rate, etc.)

# Step 3a: Promote — gradually shift traffic to canary
kubectl scale deployment/nginx-canary --replicas=2 -n canary-demo    # 33%
kubectl scale deployment/nginx-stable --replicas=3 -n canary-demo
# Wait and observe...
kubectl scale deployment/nginx-canary --replicas=4 -n canary-demo    # 50%
kubectl scale deployment/nginx-stable --replicas=2 -n canary-demo
# Wait and observe...
kubectl scale deployment/nginx-canary --replicas=4 -n canary-demo    # 80%
kubectl scale deployment/nginx-stable --replicas=1 -n canary-demo
# Full promotion:
kubectl scale deployment/nginx-stable --replicas=0 -n canary-demo
# Now update stable to v2 and restart:
kubectl set image deployment/nginx-stable nginx=nginx:1.25 -n canary-demo
kubectl scale deployment/nginx-stable --replicas=4 -n canary-demo
kubectl delete deployment/nginx-canary -n canary-demo

# Step 3b: Rollback — if canary has problems
kubectl delete deployment/nginx-canary -n canary-demo
# Stable continues serving 100% of traffic — no other action needed
```

---

## Rollback Procedure

```bash
# Simply delete the canary deployment.
# The service selector routes only to the app label (shared by both),
# so removing canary pods means 100% of traffic goes to stable immediately.
kubectl delete deployment/nginx-canary -n canary-demo
```

Rollback is immediate and requires no restarts.

---

## When to Use Canary

**Use when:**
- You want to validate new code with real user traffic before full rollout.
- Your change has a measurable impact you can observe in metrics (error rate, latency, conversion rate).
- You have monitoring infrastructure to detect regressions quickly.
- Risk aversion is high (critical service, revenue-impacting changes).

**Do NOT use when:**
- The change is a breaking API change (some users on v1, some on v2 = unpredictable behavior).
- The change involves a non-backward-compatible database schema (split-brain between v1 and v2 clients writing to the same schema).
- You don't have metrics to evaluate canary health (canary without metrics is just a slower rollout with unknown risk).

---

## Files in This Directory

| File | Purpose |
|---|---|
| `namespace.yml` | Namespace for canary demo |
| `stable-deployment.yml` | v1 stable deployment (4 replicas, 80% traffic) |
| `canary-deployment.yml` | v2 canary deployment (1 replica, 20% traffic) |
| `service.yml` | Service selecting both stable and canary pods |
| `ingress.yml` | NGINX Ingress canary annotation approach (alternative to replica ratio) |
