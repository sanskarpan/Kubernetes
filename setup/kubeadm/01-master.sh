#!/usr/bin/env bash
# ==============================================================================
# 01-master.sh — Initialize the Kubernetes control-plane node
#
# Run this script on the MASTER (control-plane) node ONLY, after running
# 00-common.sh on all nodes.
#
# Usage:
#   sudo bash 01-master.sh
#
# Override settings with environment variables:
#   CONTROL_PLANE_IP=10.0.0.10 POD_CIDR=192.168.0.0/16 sudo bash 01-master.sh
#
# After this script completes:
#   - The cluster will be initialized
#   - Calico CNI will be installed
#   - A kubeadm join command will be printed for worker nodes
# ==============================================================================

set -euo pipefail

# ---- Configuration (override with env vars) -----------------------------------
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-$(hostname -I | awk '{print $1}')}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
K8S_FULL_VERSION="${K8S_FULL_VERSION:-1.32.0}"
CALICO_VERSION="${CALICO_VERSION:-3.29.0}"

# The user whose home directory will receive the kubeconfig.
# When running with sudo, SUDO_USER is the original user.
KUBE_USER="${SUDO_USER:-${USER:-root}}"
KUBE_HOME=$(eval echo "~${KUBE_USER}")

# ---- Color helpers ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
log_ok()      { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
log_section() { printf "\n${BOLD}=== %s ===${RESET}\n\n" "$*"; }

# ---- Root check ---------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  log_error "This script must be run as root (sudo)."
  exit 1
fi

# ==============================================================================
log_section "Configuration"
log_info "Control-plane IP:  ${CONTROL_PLANE_IP}"
log_info "Pod CIDR:          ${POD_CIDR}"
log_info "K8s version:       ${K8S_FULL_VERSION}"
log_info "Calico version:    ${CALICO_VERSION}"
log_info "kubeconfig user:   ${KUBE_USER}"
log_info "kubeconfig home:   ${KUBE_HOME}"

# ==============================================================================
# STEP 1: kubeadm init
# ==============================================================================
log_section "Step 1 — kubeadm init"

# Pre-flight check
log_info "Running kubeadm pre-flight checks..."
kubeadm config images pull --kubernetes-version "v${K8S_FULL_VERSION}"

log_info "Initializing control plane..."
kubeadm init \
  --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --kubernetes-version="v${K8S_FULL_VERSION}" \
  --cri-socket="unix:///var/run/containerd/containerd.sock" \
  --upload-certs \
  2>&1 | tee /tmp/kubeadm-init.log

log_ok "kubeadm init completed. Output saved to /tmp/kubeadm-init.log"

# ==============================================================================
# STEP 2: Configure kubeconfig for the current user
# ==============================================================================
log_section "Step 2 — Configure kubeconfig"

# Setup for root
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
log_ok "kubeconfig copied to /root/.kube/config"

# Setup for the non-root user (if running via sudo)
if [ "$KUBE_USER" != "root" ] && [ -d "$KUBE_HOME" ]; then
  mkdir -p "${KUBE_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${KUBE_HOME}/.kube/config"
  chown "${KUBE_USER}:${KUBE_USER}" "${KUBE_HOME}/.kube" "${KUBE_HOME}/.kube/config"
  log_ok "kubeconfig copied to ${KUBE_HOME}/.kube/config (owner: ${KUBE_USER})"
fi

# Verify kubectl works
export KUBECONFIG=/root/.kube/config
log_info "Verifying kubectl access..."
kubectl cluster-info

# ==============================================================================
# STEP 3: Install Calico CNI
# Calico is the CNI plugin. It must be installed before nodes will become Ready.
# The pod-network-cidr MUST match what was passed to kubeadm init.
# ==============================================================================
log_section "Step 3 — Install Calico CNI v${CALICO_VERSION}"

CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests"

log_info "Applying Calico Tigera operator..."
kubectl apply -f "${CALICO_URL}/tigera-operator.yaml"

log_info "Waiting for Tigera operator to be ready..."
kubectl wait --namespace tigera-operator \
  --for=condition=Available \
  deployment/tigera-operator \
  --timeout=120s

log_info "Creating Calico Installation custom resource..."
cat <<EOF | kubectl apply -f -
---
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

log_info "Waiting for Calico system pods to become ready (this may take 2-3 minutes)..."
kubectl wait --namespace calico-system \
  --for=condition=Ready \
  pod \
  --selector=app.kubernetes.io/name=calico-node \
  --timeout=300s || {
  log_warn "Calico node pods not ready within timeout. Check status with:"
  log_warn "  kubectl get pods -n calico-system"
  log_warn "  kubectl get pods -n tigera-operator"
}

# ==============================================================================
# STEP 4: Verify cluster health
# ==============================================================================
log_section "Step 4 — Cluster health check"

log_info "Waiting for control-plane node to become Ready..."
kubectl wait \
  --for=condition=Ready \
  node/"$(hostname)" \
  --timeout=120s

log_info "Cluster node status:"
kubectl get nodes -o wide

log_info "System pod status:"
kubectl get pods -n kube-system

# ==============================================================================
# STEP 5: Generate and display the worker join command
# ==============================================================================
log_section "Step 5 — Worker join command"

JOIN_COMMAND=$(kubeadm token create --print-join-command)

log_ok "Cluster initialized successfully!"
echo ""
printf "${BOLD}${YELLOW}===============================================================${RESET}\n"
printf "${BOLD}${YELLOW}  WORKER JOIN COMMAND (save this — token valid for 24 hours)   ${RESET}\n"
printf "${BOLD}${YELLOW}===============================================================${RESET}\n"
echo ""
printf "${BOLD}${GREEN}%s \\\\${RESET}\n" "sudo $JOIN_COMMAND"
printf "${BOLD}${GREEN}  --cri-socket unix:///var/run/containerd/containerd.sock${RESET}\n"
echo ""
printf "${BOLD}${YELLOW}===============================================================${RESET}\n"
echo ""

# Parse and display individual values for use with 02-worker.sh
ENDPOINT=$(echo "$JOIN_COMMAND" | awk '{print $3}')
TOKEN=$(echo "$JOIN_COMMAND" | awk '{print $5}')
CA_HASH=$(echo "$JOIN_COMMAND" | awk '{print $7}')

log_info "To use 02-worker.sh, set these environment variables on each worker:"
echo ""
printf "  export CONTROL_PLANE_ENDPOINT=\"%s\"\n" "$ENDPOINT"
printf "  export JOIN_TOKEN=\"%s\"\n" "$TOKEN"
printf "  export CA_CERT_HASH=\"%s\"\n" "$CA_HASH"
echo ""
log_info "Then run on each worker:"
echo "  sudo -E bash 02-worker.sh"
echo ""

# Save join info to a file for convenience
cat > /tmp/worker-join-info.sh <<JOINEOF
#!/usr/bin/env bash
# Generated by 01-master.sh on $(date)
# Copy this file to worker nodes and source it before running 02-worker.sh

export CONTROL_PLANE_ENDPOINT="${ENDPOINT}"
export JOIN_TOKEN="${TOKEN}"
export CA_CERT_HASH="${CA_HASH}"

echo "Variables set. Now run: sudo -E bash 02-worker.sh"
JOINEOF
chmod 600 /tmp/worker-join-info.sh
log_info "Join variables saved to /tmp/worker-join-info.sh"

log_section "Master setup complete"
log_info "Next: run 00-common.sh and then 02-worker.sh on each worker node."
