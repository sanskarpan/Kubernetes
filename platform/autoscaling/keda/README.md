# KEDA — Kubernetes Event-Driven Autoscaling

## What is KEDA?

KEDA extends the Kubernetes HPA with 50+ scalers for event-driven sources. While native HPA supports only CPU, memory, and custom metrics via the adapter, KEDA adds direct integrations with:

- Message queues: Kafka, RabbitMQ, Azure Service Bus, AWS SQS, GCP Pub/Sub
- Databases: Redis, PostgreSQL, MySQL
- Monitoring: Prometheus, Datadog, New Relic
- Scheduling: Cron (scale up during business hours, down overnight)
- HTTP traffic: KEDA HTTP Add-on for request-based scaling
- And many more: <https://keda.sh/docs/scalers/>

KEDA also supports **scaling to zero replicas**, which the native HPA cannot do. This makes it ideal for batch jobs, event processors, and development environments where idle cost matters.

## How KEDA Works

```
[Event Source]  -->  [KEDA Operator]  -->  [HPA]  -->  [Deployment]
 (Prometheus,         watches ScaledObject    managed
  SQS, Kafka,         polls trigger values    by KEDA
  Cron, ...)          exposes via external
                      metrics API
```

1. You create a `ScaledObject` referencing your Deployment and defining triggers.
2. KEDA creates and manages an HPA for the Deployment automatically.
3. KEDA's metric adapter polls the trigger sources at `pollingInterval`.
4. The HPA scales the Deployment based on the metric values KEDA reports.
5. At zero replicas, KEDA itself watches the event source and scales from 0 to 1 when events arrive (the HPA takes over from 1 upward).

## Installation

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.14.0
```

Verify the installation:

```bash
kubectl get pods -n keda
kubectl get crd | grep keda
```

## When to Use KEDA vs Native HPA

| Scenario | Use | Reason |
|---|---|---|
| Scale on CPU or memory | Native HPA | No extra components needed |
| Scale on HTTP request rate (via Prometheus) | Either | KEDA is simpler; Prometheus Adapter is more universal |
| Scale on Kafka consumer lag | KEDA | Native HPA has no Kafka integration |
| Scale on SQS queue depth | KEDA | Native HPA has no SQS integration |
| Scale to **zero** replicas | KEDA | HPA minimum is 1 |
| Scale on a cron schedule | KEDA | Use the `cron` scaler |
| Multiple triggers (e.g., RPS AND queue depth) | KEDA | Cleaner API than maintaining multiple HPAs |
| Prometheus Adapter already installed | Native HPA | Avoid adding KEDA just for Prometheus |

## Key Concepts

### ScaledObject vs ScaledJob

- **ScaledObject**: scales a `Deployment`, `StatefulSet`, or custom resource. Use for long-running services.
- **ScaledJob**: creates Kubernetes `Job` objects on demand (one Job per event batch). Use for batch processing where each work item needs its own Job.

### Scale to Zero

```yaml
spec:
  minReplicaCount: 0  # Allow scaling to zero
  maxReplicaCount: 10
```

When at zero, KEDA uses an **activation threshold** (`activationThreshold`) to decide when to scale from 0 to 1. The HPA takes over from 1 upward.

Warning: scaling from zero causes a cold-start delay. Use `minReplicaCount: 1` for latency-sensitive services.

### cooldownPeriod

The `cooldownPeriod` (seconds) controls how long KEDA waits after the last trigger fires before allowing scale-down. Set it higher than your traffic's natural burst interval to avoid thrashing.

## Checking KEDA Status

```bash
# Check ScaledObjects
kubectl get scaledobject -A

# See which HPA KEDA created
kubectl get hpa -n <namespace>

# View KEDA operator logs for debugging
kubectl logs -n keda -l app=keda-operator --tail=50
```
