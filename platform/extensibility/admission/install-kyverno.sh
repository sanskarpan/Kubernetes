#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# install-kyverno.sh — Install Kyverno policy engine via Helm
# ==============================================================================
# Installs Kyverno and then applies all policies from the policies/ directory.
#
# Environment variables:
#   KYVERNO_VERSION - Helm chart version (default: 3.2.0)
#   NAMESPACE       - Target namespace (default: kyverno)
#
# Usage:
#   ./install-kyverno.sh
#   KYVERNO_VERSION=3.3.0 ./install-kyverno.sh
#
# After installation:
#   kubectl get pods -n kyverno
#   kubectl get clusterpolicy
#   kubectl get policyreport -A
# ==============================================================================

KYVERNO_VERSION="${KYVERNO_VERSION:-3.2.0}"
NAMESPACE="${NAMESPACE:-kyverno}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Adding Kyverno Helm repo..."
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

echo "==> Installing Kyverno ${KYVERNO_VERSION} into namespace '${NAMESPACE}'..."
helm upgrade --install kyverno kyverno/kyverno \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --set replicaCount=1

echo "==> Waiting for Kyverno to be ready..."
kubectl rollout status deployment kyverno -n "${NAMESPACE}" --timeout=120s

echo "==> Applying policies from ${SCRIPT_DIR}/policies/ ..."
kubectl apply -f "${SCRIPT_DIR}/policies/"

echo ""
echo "Done. Check policy violations:"
echo "  kubectl get policyreport -A"
echo "  kubectl get clusterpolicy"
