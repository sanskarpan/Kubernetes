# Autoscaling in Kubernetes: HPA vs VPA

## Overview

Kubernetes provides two primary autoscaling mechanisms for workloads:

| Feature | HPA (Horizontal Pod Autoscaler) | VPA (Vertical Pod Autoscaler) |
|---|---|---|
| What it scales | Number of pod replicas | CPU/memory requests & limits per pod |
| Best for | Stateless services with variable traffic | Right-sizing, resource tuning |
| Metric sources | CPU, memory, custom metrics | Historical resource usage |
| Disruption | None (adds/removes pods) | Pod restart required (in Auto mode) |
| API built-in | Yes (`autoscaling/v2`) | No — separate CRD installation |

---

## When to Use HPA

Use HPA when:

- Your workload is **stateless** (web servers, API gateways, workers)
- You can handle **variable traffic** by adding more pod replicas
- You have **predictable scaling triggers** (CPU spikes, queue depth, RPS)
- Your container images are fast to start (short startup time)

HPA is the default recommendation for most production workloads. It scales out (more pods) rather than up (bigger pods), which is safer and more compatible with Kubernetes scheduling.

**Metric sources HPA supports (v2 API):**
- `Resource` — CPU and memory utilization against requests
- `ContainerResource` — per-container metrics (multi-container pods)
- `Pods` — custom metric averaged across all pods in the target
- `Object` — custom metric from a specific Kubernetes object
- `External` — metric from a system outside Kubernetes (e.g., SQS queue depth)

---

## When to Use VPA

Use VPA when:

- You don't know the right resource requests for a workload (use `updateMode: Off` first)
- Your workload is **stateful or bursty** and can't easily scale horizontally
- You want to **right-size** requests to reduce waste and improve scheduling
- You're running **batch jobs** or workloads with inconsistent resource needs

VPA continuously observes resource usage and recommends (or applies) new resource requests. In `Auto` mode, it evicts pods to apply updated resource values — plan for this disruption.

**VPA modes:**
| Mode | Behavior |
|------|----------|
| `Off` | Recommendations only — no changes applied |
| `Initial` | Sets resources on pod creation only — never modifies running pods |
| `Auto` | Evicts and recreates pods to apply updated resource values |

---

## Can HPA and VPA Work Together?

**Yes — with important caveats.**

You **must not** let HPA and VPA both control the same metric. The conflict scenario:

1. VPA increases CPU requests → HPA sees lower utilization → HPA scales down
2. Lower utilization triggers VPA to reduce requests → HPA scales up
3. Loop repeats, thrashing replicas and evicting pods

**Safe combinations:**
- HPA on CPU/memory + VPA in `Off` or `Initial` mode only (VPA provides recommendations, HPA controls replicas)
- HPA on **custom metrics** (e.g., RPS, queue depth) + VPA on **CPU/memory** (no overlap)
- Use [KEDA](https://keda.sh) as an alternative to avoid this complexity entirely

**Recommended pattern for most teams:** Start with VPA in `Off` mode to get right-sizing recommendations, apply them manually to your deployment, then enable HPA.

---

## Metrics Server Requirement

Both HPA (for CPU/memory) and VPA require [Metrics Server](https://github.com/kubernetes-sigs/metrics-server) to be installed in the cluster. Metrics Server collects resource usage data from the kubelet on each node.

**Installation:**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**Verify it's working:**
```bash
kubectl top nodes
kubectl top pods -A
```

If `kubectl top` returns data, Metrics Server is healthy.

> **Note:** In some environments (e.g., kubeadm clusters without TLS-verified kubelets), you may need to add `--kubelet-insecure-tls` to the Metrics Server deployment args. Do NOT do this in production without understanding the security implications.

---

## Custom Metrics via Prometheus Adapter

For HPA to scale on application-specific metrics (e.g., HTTP requests per second, queue depth, active sessions), you need the [Prometheus Adapter](https://github.com/kubernetes-sigs/prometheus-adapter).

**Architecture:**
```
Application → Prometheus (scrapes metrics) → Prometheus Adapter → custom.metrics.k8s.io API → HPA
```

**Installation:**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://monitoring-prometheus.monitoring.svc.cluster.local \
  --set prometheus.port=9090
```

**Verify custom metrics are available:**
```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq .
```

**Example HPA using a custom metric:**
```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"  # target 100 RPS per pod
```

---

## External Metrics (e.g., SQS, Pub/Sub)

For scaling on external queue depths or cloud metrics, consider [KEDA (Kubernetes Event-Driven Autoscaling)](https://keda.sh). KEDA provides 50+ built-in scalers (AWS SQS, Azure Service Bus, Kafka, Redis, etc.) and is significantly easier to configure than the raw External metrics API.

---

## Decision Tree

```
Is the workload stateless and can it run multiple replicas?
├── YES → Use HPA
│   ├── Traffic/CPU driven? → HPA on cpu/memory
│   ├── Queue/event driven? → HPA + KEDA
│   └── Don't know right resource sizes? → Add VPA in Off mode alongside
└── NO (stateful, singleton)
    └── Use VPA (Auto or Initial mode)
        └── Consider StatefulSet + manual scaling for databases
```

---

## Directory Structure

```
autoscaling/
├── README.md                  ← This file
├── hpa/
│   ├── README.md              ← HPA deep dive
│   ├── hpa-cpu-memory.yml     ← HPA with CPU + memory metrics
│   └── hpa-with-behavior.yml  ← HPA with behavior block demo
└── vpa/
    ├── README.md              ← VPA guide
    └── vpa-auto.yml           ← VPA in Auto mode
```
