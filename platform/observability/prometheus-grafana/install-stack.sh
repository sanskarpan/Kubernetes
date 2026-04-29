#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# install-stack.sh — Install kube-prometheus-stack via Helm
# ==============================================================================
# Installs Prometheus, Alertmanager, Grafana, node-exporter, and
# kube-state-metrics into the monitoring namespace using the
# kube-prometheus-stack Helm chart.
#
# Environment variables (override via export or inline):
#   NAMESPACE     - Target namespace (default: monitoring)
#   RELEASE       - Helm release name (default: monitoring)
#   CHART_VERSION - Pinned chart version (default: 65.1.1)
#
# Usage:
#   ./install-stack.sh
#   NAMESPACE=obs ./install-stack.sh
#   CHART_VERSION=66.0.0 ./install-stack.sh
#
# After installation, access Grafana:
#   kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
#   Open: http://localhost:3000 (admin / password shown below)
# ==============================================================================

NAMESPACE="${NAMESPACE:-monitoring}"
RELEASE="${RELEASE:-monitoring}"
CHART_VERSION="${CHART_VERSION:-65.1.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Adding prometheus-community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> Installing kube-prometheus-stack ${CHART_VERSION} into namespace '${NAMESPACE}'..."
helm upgrade --install "${RELEASE}" prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  -f "${SCRIPT_DIR}/values-prometheus.yaml" \
  -f "${SCRIPT_DIR}/values-grafana.yaml"

echo "==> Waiting for Prometheus to be ready..."
kubectl rollout status deployment "${RELEASE}-kube-state-metrics" -n "${NAMESPACE}" --timeout=120s
kubectl rollout status deployment "${RELEASE}-grafana" -n "${NAMESPACE}" --timeout=120s

echo ""
echo "==> Grafana admin password:"
kubectl get secret -n "${NAMESPACE}" "${RELEASE}-grafana" \
  -o jsonpath="{.data.admin-password}" | base64 -d
echo ""

echo ""
echo "==> Access Grafana:"
echo "    kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-grafana 3000:80"
echo "    Open: http://localhost:3000"
echo ""
echo "==> Access Prometheus:"
echo "    kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-kube-prometheus-prometheus 9090:9090"
echo "    Open: http://localhost:9090"
echo ""
echo "==> Access Alertmanager:"
echo "    kubectl port-forward -n ${NAMESPACE} svc/${RELEASE}-kube-prometheus-alertmanager 9093:9093"
echo "    Open: http://localhost:9093"
