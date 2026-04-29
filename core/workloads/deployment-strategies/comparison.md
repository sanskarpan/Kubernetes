# Deployment Strategies — Full Comparison

## At a Glance

| Attribute | Recreate | Rolling Update | Blue-Green | Canary |
|---|---|---|---|---|
| **Downtime** | Yes (brief) | None (with readinessProbe) | None | None |
| **Rollback Speed** | Slow (redeploy) | Medium (rollout undo) | Instant (selector flip) | Fast (delete canary) |
| **Resource Overhead** | None | Minimal (maxSurge pods) | 2x (full duplicate env) | Small (few extra pods) |
| **Risk Level** | High (all users affected) | Low-Medium | Low | Lowest |
| **Traffic Control** | None | None | All-or-nothing switch | Gradual (replica ratio or ingress weights) |
| **Rollback Control** | None | `kubectl rollout undo` | Change service selector | Delete canary deployment |
| **Complexity** | Very Low | Low | Medium | Medium-High |
| **Environment Parity** | N/A | High | Highest (exact duplicate) | High |
| **Schema Migration Compatible?** | Yes (downtime window) | Only if backward-compatible | Yes (run migration on green before switch) | Requires dual-write compatibility |

---

## Detailed Analysis

### Recreate

**How it works:** The Deployment controller scales the old ReplicaSet down to 0, waits for all old pods to terminate, then scales the new ReplicaSet up. All pods are on the new version simultaneously.

**Downtime:** Yes — the time between the last old pod dying and the first new pod becoming Ready. Typically 10–60 seconds depending on startup time.

**When to use:**
- Development and staging environments where downtime is acceptable.
- Applications that cannot run two versions simultaneously (e.g., schema changes that are incompatible with the old binary).
- Singleton processes that must not overlap (e.g., a worker that holds an exclusive lock).

**When NOT to use:** Production environments with SLO requirements. Any user-facing service.

**Industry example:** Dev environments everywhere. Netflix uses recreate for internal tooling with no SLA.

---

### Rolling Update

**How it works:** Kubernetes replaces pods one at a time (or in small batches). For each step, new pods are started and old pods are terminated only after new ones are Ready. `maxSurge` controls how many extra pods can exist during the rollout; `maxUnavailable` controls how many pods can be offline simultaneously.

**Zero-downtime requirement:** The readinessProbe is **essential**. Without it, Kubernetes sends traffic to new pods before they are ready to serve requests, causing errors. The readinessProbe gates when a pod is added to the Service endpoint list.

**Downtime:** None, if readinessProbe is correctly configured and `maxUnavailable: 0`.

**When to use:**
- The default choice for most stateless applications.
- When you have 2+ replicas and a working readinessProbe.
- When the new and old versions can run simultaneously (API-backward-compatible changes).

**When NOT to use:**
- Single-replica deployments (any `maxUnavailable > 0` causes downtime).
- Schema changes incompatible with the running version.

**Industry example:** Google uses rolling updates as the default for most services. Kubernetes itself uses rolling updates for its own control-plane components.

---

### Blue-Green

**How it works:** Two complete, identical environments exist in parallel — "blue" (current production) and "green" (new version). Traffic is served entirely by blue. When green is tested and ready, a single change flips the Service selector from blue to green. Blue is kept as a hot standby for instant rollback.

**Traffic switch:** Change the Service's label selector:
```bash
# Switch from v1 (blue) to v2 (green)
kubectl patch service myapp -p '{"spec":{"selector":{"version":"v2"}}}'

# Rollback — switch back to v1 (blue)
kubectl patch service myapp -p '{"spec":{"selector":{"version":"v1"}}}'
```

**Downtime:** None — the selector change propagates in milliseconds via kube-proxy iptables updates.

**Resource overhead:** 2x — you run a full duplicate of your application for the duration of the release window.

**Rollback speed:** Instant — reverse the selector. No pod restarts required.

**When to use:**
- High-stakes releases where instant rollback is non-negotiable.
- Applications with complex startup sequences that make rolling updates slow.
- Schema migrations that need to be validated on green with production-like data before switching.
- Compliance environments requiring zero-downtime with verifiable audit trails.

**When NOT to use:**
- Cost-sensitive environments (2x resource cost).
- Stateful applications where two versions cannot share the same data layer.
- Microservices with many dependencies (maintaining two complete environments is operationally complex).

**Industry example:** Amazon uses blue-green for Route 53 weighted routing at the DNS level. Netflix uses it with Spinnaker for pipeline-controlled releases.

---

### Canary

**How it works:** A small "canary" deployment runs alongside the stable deployment. Both are selected by the same Service, so traffic is split proportionally by replica count. With 4 stable replicas and 1 canary replica, ~20% of traffic hits the canary. After validating metrics (error rate, latency, business KPIs), the canary is promoted (scaled up) and the stable version is scaled down.

**Traffic split approaches:**
1. **Replica ratio (Kubernetes-native):** 4 stable + 1 canary = 20% canary. Simple but coarse-grained.
2. **Ingress annotations (NGINX/Traefik):** Precise percentage control (e.g., 5%) regardless of replica count. See `canary/ingress.yml`.
3. **Service Mesh (Istio/Linkerd):** Sub-1% routing, header-based routing, weighted virtual services. Most powerful.

**Rollback:** Delete the canary Deployment. Traffic automatically returns 100% to stable.

**Promote canary:**
```bash
# Promote: scale up canary to full capacity
kubectl scale deployment myapp-canary --replicas=4 -n canary-demo
# Then remove the stable deployment (or update it to v2 and retire canary)
kubectl delete deployment myapp-stable -n canary-demo
```

**When to use:**
- High-risk changes where you need real user validation before full rollout.
- A/B testing (send specific user segments to canary).
- Applications where you can define measurable success criteria (error rate < 0.1%, p99 latency < 200ms).

**When NOT to use:**
- Stateful operations where split-brain between v1 and v2 clients is dangerous.
- Simple schema changes (all users should be on the same schema).
- When you don't have metrics infrastructure to validate canary health.

**Industry example:** Google's SRE book describes canary deployments as the standard for Search and Maps releases. Airbnb, LinkedIn, and Uber all use canary deployments with feature flags for risk-controlled rollouts.

---

## Choosing the Right Strategy for Your Situation

| Situation | Recommended Strategy |
|---|---|
| Dev/staging, need fast iteration | Recreate |
| Production, low-risk change, stateless app | Rolling Update |
| Production, needs backward-compatible schema change | Rolling Update with carefully ordered migration |
| Production, high-risk release, need instant rollback | Blue-Green |
| Production, need user traffic validation | Canary |
| Production, need to test with specific users (beta program) | Canary with header-based routing (Istio) |
| High cost sensitivity | Rolling Update (minimal overhead) |
| Regulatory/compliance requirement for zero-downtime | Blue-Green |
| Breaking API change | Blue-Green (coordinate client migration) |

## Resource Cost Summary

```
Recreate:       ████░░░░░░  1.0x (no extra pods)
Rolling Update: █████░░░░░  1.1x (only 1-2 surge pods)
Blue-Green:     ██████████  2.0x (full duplicate environment)
Canary:         ██████░░░░  1.2x (a few extra canary pods)
```
