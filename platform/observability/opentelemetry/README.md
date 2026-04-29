# OpenTelemetry Collector

## Architecture Overview

OpenTelemetry (OTel) is a CNCF project providing a vendor-neutral observability framework. It standardizes how telemetry data (traces, metrics, logs) is collected, processed, and exported.

```
                    ┌─────────────────────────────────────────┐
                    │         OTel Collector (this file)       │
                    │                                          │
Applications        │  Receivers    Processors   Exporters    │
──────────────────► │  ─────────    ──────────   ─────────    │ ──► Jaeger (traces)
  OTLP gRPC :4317  │  otlp         memory_      otlp         │
  OTLP HTTP :4318  │  prometheus   limiter       logging      │ ──► Prometheus (metrics)
                    │               batch                      │
                    │                                          │
                    └─────────────────────────────────────────┘
```

### Three Signals

| Signal | Description | Receiver | Exporter |
|---|---|---|---|
| **Traces** | Distributed request traces (spans, context propagation) | OTLP | Jaeger, Tempo, Zipkin |
| **Metrics** | Numeric measurements over time (counters, gauges, histograms) | OTLP, Prometheus | Prometheus, Cortex, Mimir |
| **Logs** | Structured log events with trace correlation | OTLP | Loki, Elasticsearch |

## Deployment Modes

| Mode | When to Use |
|---|---|
| **Deployment** (this file) | Central aggregation point. All apps send to one collector cluster. |
| **DaemonSet** | Per-node agent for host metrics, log tailing, or low-latency local collection. |
| **Sidecar** | Per-pod isolation. Use the OTel Operator to inject sidecars automatically. |

For most clusters: deploy a central Deployment collector (this file) and have apps send directly to it.

## Instrumenting Your Application

### Go

```go
import "go.opentelemetry.io/otel"

// Initialize with OTLP gRPC exporter
exporter, _ := otlptracehttp.New(ctx,
    otlptracehttp.WithEndpoint("otel-collector.observability.svc.cluster.local:4317"),
    otlptracehttp.WithInsecure(),
)
```

### Python

```python
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

exporter = OTLPSpanExporter(
    endpoint="otel-collector.observability.svc.cluster.local:4317",
    insecure=True,
)
```

### Environment Variables (Zero-Code Instrumentation)

For Java, Node.js, and Python with the OTel auto-instrumentation agent, set:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.observability.svc.cluster.local:4317"
  - name: OTEL_SERVICE_NAME
    value: "myapp"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "deployment.environment=production,k8s.namespace.name=$(MY_POD_NAMESPACE)"
```

## OTel Operator (Advanced)

The [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator) provides:

- **Auto-instrumentation injection**: annotate a Deployment and the operator injects the OTel SDK automatically (no code changes).
- **Collector CRD**: manage the Collector via an `OpenTelemetryCollector` CR instead of raw Deployment + ConfigMap.
- **Target Allocator**: for the Prometheus receiver in DaemonSet mode, distributes scrape targets across collector instances.

Install the operator:

```bash
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

## Checking Collector Health

```bash
# Check collector pods
kubectl get pods -n observability -l app.kubernetes.io/name=otel-collector

# View pipeline logs
kubectl logs -n observability -l app.kubernetes.io/name=otel-collector --tail=50

# Check self-metrics (throughput, drop rates)
kubectl port-forward -n observability svc/otel-collector 8888:8888
curl http://localhost:8888/metrics | grep otelcol_receiver
```

Key self-metrics to watch:

- `otelcol_receiver_accepted_spans_total`: spans successfully received
- `otelcol_exporter_send_failed_spans_total`: spans that could not be exported (backend down)
- `otelcol_processor_batch_batch_size_trigger_send_total`: how often batches are flushed
