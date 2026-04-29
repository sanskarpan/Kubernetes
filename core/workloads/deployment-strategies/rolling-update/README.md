# Rolling Update Strategy

## What Is It?

Rolling Update is the **default Kubernetes deployment strategy**. It replaces pods incrementally — a few old pods are taken down and new pods are brought up at a time, ensuring the application always has some pods running and serving traffic throughout the entire update process.

When done correctly (with a readinessProbe and `maxUnavailable: 0`), Rolling Update achieves **true zero-downtime deployment**.

---

## Key Parameters

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1          # How many EXTRA pods above desired count can exist during rollout
    maxUnavailable: 0    # How many pods can be UNAVAILABLE (below desired count) during rollout
```

### maxSurge

The maximum number of pods that can be scheduled ABOVE the desired replica count during an update. With `replicas: 4` and `maxSurge: 1`, up to 5 pods can run simultaneously during the rollout.

- `maxSurge: 0` — No extra pods. Old pods are killed before new ones start. Slower but uses fewer resources.
- `maxSurge: 1` — One extra pod at a time. Balanced approach.
- `maxSurge: 25%` — Percentage of desired replicas. `replicas: 4, maxSurge: 25%` = 1 extra pod.
- `maxSurge: 100%` — All new pods start before any old ones are killed (surge-heavy rollout, fast but 2x resources temporarily).

### maxUnavailable

The maximum number of pods that can be UNAVAILABLE (not Ready) during an update.

- `maxUnavailable: 0` — **Zero-downtime guarantee.** No pod is taken down until a replacement is Ready. This requires `maxSurge > 0` (otherwise the rollout would stall).
- `maxUnavailable: 1` — One pod can be offline at a time. Slightly faster rollout, small risk of reduced capacity.
- `maxUnavailable: 25%` — Up to 25% of pods can be offline simultaneously. Fast rollout, significant capacity reduction.

**Production recommendation:** `maxSurge: 1, maxUnavailable: 0` — guarantees zero downtime while limiting resource overhead to one extra pod.

---

## Why readinessProbe Is Critical for Zero Downtime

Without a readinessProbe, Kubernetes adds a new pod to the Service endpoint list the moment the pod's containers are **started** — not when they are **ready to serve traffic**. If your application takes 15 seconds to initialize (load config, warm up caches, establish DB connections), traffic sent to the pod during those 15 seconds will fail.

With a readinessProbe:
1. Kubernetes starts the new pod.
2. The readinessProbe runs repeatedly. The pod is NOT added to Service endpoints yet.
3. When the readinessProbe succeeds, the pod is marked Ready and added to Service endpoints.
4. Only then does the controller start terminating an old pod.

This is the mechanism that makes zero-downtime rolling updates possible. **If your readinessProbe is wrong (too lenient, wrong path, wrong port), you will have downtime during rolling updates.**

```yaml
readinessProbe:
  httpGet:
    path: /healthz   # Must return 2xx only when the app is truly ready to serve traffic
    port: 8080
  initialDelaySeconds: 5    # Wait this long before first check (let app start)
  periodSeconds: 5          # Check every 5 seconds
  failureThreshold: 3       # 3 consecutive failures = mark pod not ready
  successThreshold: 1       # 1 success = mark pod ready
```

> **Interview Callout:** "How does Kubernetes achieve zero-downtime rolling updates?" — The readinessProbe gates when a new pod receives traffic. With `maxUnavailable: 0`, Kubernetes guarantees that at least N replicas are always Ready. The controller only terminates an old pod AFTER a new pod passes its readinessProbe and becomes Ready.

---

## Rollback

```bash
# View rollout history
kubectl rollout history deployment/nginx-rolling -n rolling-demo

# Roll back to the previous version
kubectl rollout undo deployment/nginx-rolling -n rolling-demo

# Roll back to a specific revision
kubectl rollout undo deployment/nginx-rolling -n rolling-demo --to-revision=2
```

The rollback itself is a Rolling Update in reverse — it uses the same `maxSurge` and `maxUnavailable` parameters, so it is also zero-downtime (assuming the old version's pods pass their readinessProbe).

---

## How to Apply

```bash
kubectl apply -f rolling-update/

# Watch the rollout
kubectl rollout status deployment/nginx-rolling -n rolling-demo

# Trigger an update (change image)
kubectl set image deployment/nginx-rolling nginx=nginx:1.25 -n rolling-demo

# Watch pods — you will see new pods start before old pods are terminated
kubectl get pods -n rolling-demo -w
```

## Pause and Resume a Rollout

```bash
# Pause mid-rollout (e.g., to make additional changes before continuing)
kubectl rollout pause deployment/nginx-rolling -n rolling-demo

# Make additional changes while paused
kubectl set env deployment/nginx-rolling APP_VERSION=v2 -n rolling-demo

# Resume — all paused changes are applied together as one rollout
kubectl rollout resume deployment/nginx-rolling -n rolling-demo
```
