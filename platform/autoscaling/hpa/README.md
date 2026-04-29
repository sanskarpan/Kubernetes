# Horizontal Pod Autoscaler (HPA) — Deep Dive

## v2 API vs v1 (Why v1 is Deprecated)

The `autoscaling/v1` API only supported a single metric: **CPU utilization**. Every field beyond `targetCPUUtilizationPercentage` was either absent or stored in a JSON annotation hack. It offered no `behavior` block, no memory metrics, and no custom/external metrics.

The `autoscaling/v2` API (stable since Kubernetes 1.23) is the current standard and supports:
- Multiple simultaneous metrics (CPU + memory + custom)
- The `behavior` block (scale-up/scale-down speed control)
- `ContainerResource` metrics (per-container in multi-container pods)
- `Object` and `External` metric types

**Always use `autoscaling/v2`.** The v1 API is deprecated and removed in Kubernetes 1.26+. Any tooling or docs still referencing v1 are outdated.

---

## Metric Types

### Resource Metrics (CPU and Memory)

Resource metrics measure utilization relative to each pod's **requests** (not limits). This is why correct resource requests are critical — if requests are too low, the HPA will think pods are heavily loaded and scale out unnecessarily.

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: AverageUtilization  # percentage of requested CPU
        averageUtilization: 70    # scale when average pod CPU > 70% of request
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageUtilization
        averageUtilization: 80
```

**Formula:** `desiredReplicas = ceil(currentReplicas * (currentMetricValue / desiredMetricValue))`

### Custom Metrics

Custom metrics require the [Prometheus Adapter](https://github.com/kubernetes-sigs/prometheus-adapter) or another custom metrics provider.

```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"
```

### External Metrics

External metrics come from systems outside Kubernetes (cloud queues, etc.). Consider KEDA instead, which is purpose-built for this.

---

## Stabilization Window — Preventing Flapping

The stabilization window prevents the HPA from making rapid back-and-forth decisions when a metric hovers near the threshold. Without it, a metric bouncing between 68% and 72% around a 70% target would cause constant scale-up/scale-down events.

**How it works:**
- The HPA keeps a sliding window of past metric values and recommendations
- For scale-down: it uses the **highest** recommendation in the window (conservative — avoids premature scale-down)
- For scale-up: it uses the **lowest** recommendation in the window (can be 0 for immediate response)

**Default values (if behavior block is absent):**
- Scale-down stabilization: 300 seconds (5 minutes)
- Scale-up stabilization: 0 seconds (immediate)

---

## Scale-Down vs Scale-Up Speeds

The `behavior` block gives fine-grained control over how fast the HPA can add or remove pods.

### Why slow scale-down matters

If your application takes 30 seconds to initialize and traffic spikes recur every few minutes, scaling down to minimum and then back up creates startup latency for users. A conservative scale-down window keeps a buffer of pods ready.

### Why immediate scale-up matters

Latency spikes during traffic surges are user-visible. Scale-up should be as fast as possible. The default `stabilizationWindowSeconds: 0` for scale-up is correct — don't add a window here unless you have a specific reason.

### Policy types

| Type | Meaning |
|------|---------|
| `Pods` | Add/remove at most N pods per `periodSeconds` |
| `Percent` | Add/remove at most N% of current replicas per `periodSeconds` |

Multiple policies can be combined; the `selectPolicy` field (`Max` or `Min`) determines which constraint wins:
- `selectPolicy: Max` — allow the **largest** change (faster scaling)
- `selectPolicy: Min` — allow the **smallest** change (more conservative, default)

---

## Behavior Block Reference

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300   # Wait 5 min before acting on scale-down
    selectPolicy: Min                  # Use the most conservative policy
    policies:
      - type: Percent
        value: 50
        periodSeconds: 60             # Remove at most 50% of pods per minute
      - type: Pods
        value: 2
        periodSeconds: 60             # OR at most 2 pods per minute
  scaleUp:
    stabilizationWindowSeconds: 0     # React immediately to scale-up signals
    selectPolicy: Max                  # Use the most aggressive policy
    policies:
      - type: Pods
        value: 4
        periodSeconds: 60             # Add at most 4 pods per minute
      - type: Percent
        value: 100
        periodSeconds: 60             # OR double the pod count per minute
```

---

## Demo: Load Testing with Busybox to Trigger HPA

This demo assumes you have a Deployment named `nginx-deployment` in the `workloads` namespace with the HPA from `hpa-cpu-memory.yml` applied.

### Step 1: Apply the HPA

```bash
kubectl apply -f hpa-cpu-memory.yml
kubectl get hpa -n workloads nginx-hpa --watch
```

### Step 2: Open a second terminal — watch the HPA

```bash
watch -n 2 "kubectl get hpa -n workloads nginx-hpa && echo && kubectl get pods -n workloads -l app.kubernetes.io/name=nginx"
```

### Step 3: Generate load from a busybox pod

```bash
# Run in a loop — sends continuous HTTP requests to the nginx service
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  --rm -it \
  -n workloads \
  -- /bin/sh -c "while true; do wget -q -O- http://nginx-service.workloads.svc.cluster.local; done"
```

### Step 4: Observe scale-up

Within ~60–90 seconds (one HPA sync cycle), you should see:
```
NAME        REFERENCE                     TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
nginx-hpa   Deployment/nginx-deployment   88%/70%, ...    2         10        4          3m
```

### Step 5: Stop load and observe scale-down

Delete the load-generator pod (Ctrl+C if running interactively, or `kubectl delete pod load-generator -n workloads`).

Due to the 300-second stabilization window for scale-down, replicas will remain elevated for ~5 minutes before reducing.

### Step 6: Inspect HPA events

```bash
kubectl describe hpa -n workloads nginx-hpa
# Look for Events section — shows each scale decision with reason
```

---

## Useful Commands

```bash
# View current HPA status with metrics
kubectl get hpa -n workloads -o wide

# Watch HPA in real time
kubectl get hpa -n workloads --watch

# Full detail including events and conditions
kubectl describe hpa -n workloads nginx-hpa

# View raw metrics the HPA is reading
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/workloads/pods" | jq .

# Check HPA conditions (Useful for diagnosing "unable to get metrics" errors)
kubectl get hpa -n workloads nginx-hpa -o jsonpath='{.status.conditions}' | jq .
```

---

## Common Problems

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| `unable to get metrics for resource cpu` | Metrics Server not installed | Install metrics-server |
| HPA stuck at min replicas despite high load | Resource requests not set on pods | Set `resources.requests.cpu` |
| HPA flapping (scaling up and down rapidly) | Missing stabilization window | Add `behavior.scaleDown.stabilizationWindowSeconds` |
| `FailedGetScale` error | RBAC — HPA controller can't read the target | Check HPA controller ServiceAccount permissions |
| Replicas don't go below `minReplicas` | This is correct behavior | HPA never goes below min |
