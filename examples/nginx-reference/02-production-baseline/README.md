# Production Baseline — nginx Reference

This directory contains a complete, production-grade nginx deployment demonstrating
all security and reliability requirements enforced on a hardened Kubernetes platform.

Every setting is explained inline in the manifests. This README explains WHY each
resource exists and how the pieces connect.

---

## Files and Why They Exist

### `namespace.yml` — Security Boundary

The Namespace does two things:

1. **Isolation:** Resources in this namespace share a name space (pun intended) but
   are isolated from resources in other namespaces by default.

2. **Pod Security Admission (PSA):** The `pod-security.kubernetes.io/*` labels enforce
   the **Restricted** Pod Security Standard. Any Pod that doesn't satisfy Restricted
   requirements (non-root, no privilege escalation, seccomp, etc.) is **rejected**.

```bash
# See what PSA enforces in this namespace
kubectl get namespace production-baseline -o yaml | grep pod-security
```

### `deployment.yml` — The Workload

The Deployment is where most production requirements are implemented. Key decisions:

#### Why `nginxinc/nginx-unprivileged`?

Standard `nginx:1.27` listens on port 80. Binding to ports below 1024 requires the
`NET_BIND_SERVICE` capability (or running as root). The Restricted PSS forbids both.

`nginxinc/nginx-unprivileged:1.27` is the official nginx image configured to:
- Run as UID 101 (not root)
- Listen on port 8080 (not 80)
- Drop all capabilities

#### Why `readOnlyRootFilesystem: true`?

Prevents an attacker who gains code execution from writing malicious files to the
container's filesystem. Any legitimate writes must go to explicit volumes (emptyDir, PVC).

nginx needs several writable directories:
- `/tmp` — temp file storage
- `/var/cache/nginx` — proxy and fastcgi cache
- `/var/run` — PID file
- `/var/log/nginx` — log files (redirected to stdout/stderr in prod)

All four are backed by `emptyDir` volumes.

#### Why no CPU limit?

CPU limits in Kubernetes use Linux cgroups v1 CFS (Completely Fair Scheduler) quotas.
When a container hits its CPU limit, the kernel throttles it — even if the node has
spare CPU capacity.

This causes **latency spikes** because the process is forced to wait for the next
scheduler period (default: 100ms). For latency-sensitive services, this is harmful.

The recommendation (widely adopted by production platforms): set CPU **requests** for
scheduling, but omit CPU **limits**. Monitor actual CPU usage; if pods consistently
approach the request value, increase the request.

Reference: https://erickhun.com/posts/kubernetes-faster-services-no-cpu-limits/

#### Why `preStop` sleep?

When a pod is deleted:
1. kube-proxy starts removing the pod's IP from iptables rules on all nodes
2. The kubelet sends SIGTERM to the container
3. Steps 1 and 2 happen **in parallel** — there is a race condition

Without the sleep: the pod receives SIGTERM and stops, but kube-proxy hasn't finished
propagating the endpoint removal. Requests arrive at a dead pod → 502 errors.

With `sleep 5`: the pod waits 5 seconds before stopping, giving kube-proxy time to
finish propagating. After the sleep, `nginx -s quit` gracefully drains in-flight requests.

#### Why `minReadySeconds: 10`?

After a pod passes its readiness probe, Kubernetes considers it "Ready." But "Ready"
doesn't mean "fully warmed up." A pod might be ready after one successful health check
but fail on the next request due to JIT compilation, cache warming, etc.

`minReadySeconds: 10` requires the pod to remain continuously Ready for 10 seconds
before the rolling update moves to the next pod. This prevents a flapping pod from
being counted as Available prematurely.

### `service.yml` — Stable Endpoint + ServiceAccount

The **Service** provides a stable ClusterIP and DNS name (`nginx.production-baseline.svc.cluster.local`)
that routes to healthy Pods. It also contains the **ServiceAccount** definition.

Why a dedicated ServiceAccount?
- Every namespace has a `default` ServiceAccount
- Kubernetes auto-mounts a token for the `default` SA that has some permissions
- By creating a dedicated SA with no permissions and `automountServiceAccountToken: false`,
  we ensure that if the pod is compromised, the attacker gets no K8s API credentials

### `hpa.yml` — Automatic Scaling

The HPA watches CPU and memory utilisation and adjusts the replica count between 2 and 10.

Key behavior decisions:
- **Scale-up stabilization: 0s** — react immediately to traffic spikes
- **Scale-down stabilization: 300s (5 min)** — wait 5 minutes before removing pods

Why conservative scale-down? If you remove pods too quickly during a brief traffic dip,
the next request spike catches you under-provisioned and you're scaling back up under
load. The 5-minute window absorbs most traffic variance.

### `pdb.yml` — High Availability During Maintenance

The PDB says: "Never let more than 1 pod be unavailable at a time voluntarily."

Without a PDB:
- A cluster upgrade might drain 3 nodes simultaneously
- Your 2-replica Deployment loses both pods → outage

With `minAvailable: 1`:
- The cluster must ensure 1 pod is Running and Ready before draining another node
- Node drains happen sequentially, not in parallel
- Rolling Deployment updates are also constrained by the PDB

### `network-policy.yml` — Zero-Trust Networking

Four policies work together:

1. **`default-deny-all`** — blocks all ingress and egress by default
2. **`allow-ingress-controller`** — allows the nginx Ingress controller to route to pods
3. **`allow-dns-egress`** — allows pods to resolve service names via CoreDNS
4. **`allow-prometheus-scrape`** — allows Prometheus to scrape metrics

Without NetworkPolicies, any pod in any namespace can reach any other pod in the cluster.
This violates the principle of least privilege for networking.

---

## Applying the Production Baseline

```bash
# Apply in order (namespace first)
kubectl apply -f examples/nginx-reference/02-production-baseline/namespace.yml
kubectl apply -f examples/nginx-reference/02-production-baseline/service.yml
kubectl apply -f examples/nginx-reference/02-production-baseline/deployment.yml
kubectl apply -f examples/nginx-reference/02-production-baseline/pdb.yml
kubectl apply -f examples/nginx-reference/02-production-baseline/hpa.yml
kubectl apply -f examples/nginx-reference/02-production-baseline/network-policy.yml

# Or apply all at once (kubectl handles ordering)
kubectl apply -f examples/nginx-reference/02-production-baseline/
```

## Verification

```bash
# All pods Running
kubectl get pods -n production-baseline

# Security contexts applied
kubectl get pod -n production-baseline -o jsonpath='{.items[0].spec.securityContext}' | jq .

# HPA status
kubectl get hpa -n production-baseline

# PDB status
kubectl get pdb -n production-baseline

# NetworkPolicies
kubectl get networkpolicies -n production-baseline

# Attempt to exec into pod — should work (for debugging)
POD=$(kubectl get pods -n production-baseline -o name | head -1)
kubectl exec -n production-baseline ${POD} -- id
# Expected: uid=101(nginx) gid=101(nginx) groups=101(nginx)

# Attempt to write to filesystem — should fail
kubectl exec -n production-baseline ${POD} -- touch /test-file
# Expected: touch: /test-file: Read-only file system
```

## Clean Up

```bash
kubectl delete -f examples/nginx-reference/02-production-baseline/
kubectl delete namespace production-baseline
```

---

## Production Checklist

| Requirement                   | Implemented? | Where                              |
|-------------------------------|--------------|------------------------------------|
| Dedicated ServiceAccount      | Yes          | `service.yml`                      |
| automountServiceAccountToken false | Yes     | `service.yml`, `deployment.yml`    |
| runAsNonRoot                  | Yes          | `deployment.yml` podSecurityContext|
| runAsUser (non-zero)          | Yes          | UID 101                            |
| fsGroup                       | Yes          | GID 101                            |
| seccompProfile: RuntimeDefault| Yes          | `deployment.yml` podSecurityContext|
| allowPrivilegeEscalation: false | Yes        | container securityContext          |
| readOnlyRootFilesystem: true  | Yes          | container securityContext          |
| capabilities: drop ALL        | Yes          | container securityContext          |
| Resource requests             | Yes          | CPU + memory                       |
| Memory limits                 | Yes          | No CPU limit (by design)           |
| Startup probe                 | Yes          | `deployment.yml`                   |
| Liveness probe                | Yes          | `deployment.yml`                   |
| Readiness probe               | Yes          | `deployment.yml`                   |
| preStop lifecycle hook        | Yes          | `deployment.yml`                   |
| terminationGracePeriodSeconds | Yes          | 60s                                |
| Rolling update (maxUnavailable: 0) | Yes    | `deployment.yml`                   |
| minReadySeconds               | Yes          | 10s                                |
| revisionHistoryLimit          | Yes          | 5                                  |
| Pod anti-affinity             | Yes          | `deployment.yml`                   |
| PodDisruptionBudget           | Yes          | `pdb.yml`                          |
| HorizontalPodAutoscaler       | Yes          | `hpa.yml`                          |
| NetworkPolicy default-deny    | Yes          | `network-policy.yml`               |
| Full app.kubernetes.io labels | Yes          | All resources                      |
| PSA Restricted enforcement    | Yes          | `namespace.yml` labels             |
