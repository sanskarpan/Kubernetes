# Prometheus + Grafana — kube-prometheus-stack

## Overview

The [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm chart is the production-standard way to deploy a complete observability stack for Kubernetes. A single Helm release installs:

| Component | Purpose |
|-----------|---------|
| **Prometheus** | Time-series metrics collection and storage |
| **Alertmanager** | Alert routing, grouping, and notification |
| **Grafana** | Visualization and dashboards |
| **node-exporter** | Node-level hardware and OS metrics |
| **kube-state-metrics** | Kubernetes object state metrics |
| **Prometheus Operator** | CRD-based configuration for Prometheus/Alertmanager |

---

## Installation with Custom Values

```bash
# Run the included install script
./install-stack.sh

# Or manually:
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 65.1.1 \
  -f values-prometheus.yaml \
  -f values-grafana.yaml
```

### Verify installation

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring

# All components should show Running:
# monitoring-grafana-xxx                       Running
# monitoring-kube-prometheus-prometheus-xxx    Running
# monitoring-alertmanager-xxx                  Running
# monitoring-kube-state-metrics-xxx            Running
# monitoring-prometheus-node-exporter-xxx      Running (one per node)
```

---

## Accessing Grafana

### Development (port-forward)

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80

# Open: http://localhost:3000
# Default credentials:
#   Username: admin
#   Password: (output from install-stack.sh, or from the grafana Secret)
```

### Retrieve the admin password

```bash
kubectl get secret -n monitoring monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
echo
```

### Production access

For production, expose Grafana via an Ingress with TLS and authentication:

```yaml
grafana:
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - grafana.example.com
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.example.com
  grafana.ini:
    auth.generic_oauth:
      enabled: true
      # Configure OIDC for production authentication
```

---

## Default Dashboards

kube-prometheus-stack ships with pre-configured dashboards for:
- Kubernetes cluster overview (node CPU, memory, pods, PVCs)
- Kubernetes workloads (deployment status, pod restarts, resource usage)
- Node exporter (disk I/O, network, filesystem usage)
- Prometheus internals (scrape targets, rule evaluation)
- Alertmanager (active alerts, notification status)
- CoreDNS, etcd, kube-apiserver performance

Find dashboards at: http://localhost:3000/dashboards

For additional dashboards, browse [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards) and import by ID.

---

## Creating PrometheusRules (Alerting)

The Prometheus Operator watches for `PrometheusRule` CRDs and automatically loads them into Prometheus. See `alerts/` for examples.

### PrometheusRule structure

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-alerts
  namespace: monitoring
  labels:
    release: monitoring   # Must match the Prometheus Operator's ruleSelector
spec:
  groups:
    - name: my-alert-group
      rules:
        - alert: MyAlert
          expr: some_metric > threshold
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Alert summary"
            description: "Detailed description with {{ $labels.pod }}"
```

**Important:** The `release: monitoring` label must match the Prometheus Operator's `ruleSelector`. With the default kube-prometheus-stack install, all PrometheusRules in any namespace are picked up automatically.

### Verify rules are loaded

```bash
# List all PrometheusRules
kubectl get prometheusrule -A

# Check Prometheus has loaded the rule
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090
# Open: http://localhost:9090/rules
```

---

## Connecting HPA to Prometheus Adapter (Custom Metrics)

For HPA to scale on application metrics (e.g., HTTP requests per second), install the Prometheus Adapter:

```bash
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local \
  --set prometheus.port=9090
```

### Configure custom metrics

Create a ConfigMap defining how Prometheus metrics map to Kubernetes custom metrics:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-adapter
  namespace: monitoring
data:
  config.yaml: |
    rules:
      - seriesQuery: 'http_requests_total{namespace!="",pod!=""}'
        resources:
          overrides:
            namespace:
              resource: namespace
            pod:
              resource: pod
        name:
          matches: "^(.*)_total"
          as: "${1}_per_second"
        metricsQuery: 'rate(<<.Series>>{<<.LabelMatchers>>}[2m])'
```

### Verify custom metrics are available

```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq .
# Should list your custom metrics

# Test the metric value for a specific pod
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta1/namespaces/workloads/pods/*/http_requests_per_second" \
  | jq .
```

---

## Useful Prometheus Queries (PromQL)

```promql
# Pod restart rate (last 1 hour)
increase(kube_pod_container_status_restarts_total[1h])

# Container memory usage as % of limit
container_memory_working_set_bytes
  / on(pod, container, namespace)
  kube_pod_container_resource_limits{resource="memory"}
  * 100

# CPU throttle ratio (% of time CPU was throttled)
rate(container_cpu_cfs_throttled_periods_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])

# Nodes with high memory pressure
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1

# Pods in CrashLoopBackOff
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0
```

---

## Alertmanager Configuration

After installation, configure Alertmanager to route alerts to your team's channels:

```bash
kubectl edit secret -n monitoring monitoring-alertmanager-main
```

Or use a values override:

```yaml
alertmanager:
  config:
    global:
      slack_api_url: 'https://hooks.slack.com/services/...'
    route:
      group_by: ['alertname', 'cluster']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 3h
      receiver: 'slack-notifications'
      routes:
        - receiver: 'pagerduty-critical'
          match:
            severity: critical
    receivers:
      - name: 'slack-notifications'
        slack_configs:
          - channel: '#alerts'
            title: '{{ .CommonLabels.alertname }}'
            text: '{{ .CommonAnnotations.description }}'
      - name: 'pagerduty-critical'
        pagerduty_configs:
          - routing_key: '<PAGERDUTY_KEY>'
```
