#!/usr/bin/env bash
# ==============================================================================
# 02-worker.sh — Join a worker node to an existing Kubernetes cluster
#
# Run this script on each WORKER node ONLY, after:
#   1. Running 00-common.sh on this worker node.
#   2. Running 01-master.sh on the control-plane node.
#   3. Collecting the join command values from the master's output.
#
# Usage:
#   export CONTROL_PLANE_ENDPOINT="<master-ip>:6443"
#   export JOIN_TOKEN="<token>"
#   export CA_CERT_HASH="sha256:<hash>"
#   sudo -E bash 02-worker.sh
#
# Or inline:
#   CONTROL_PLANE_ENDPOINT="10.0.0.10:6443" \
#   JOIN_TOKEN="abc123.def456" \
#   CA_CERT_HASH="sha256:abcdef..." \
#   sudo -E bash 02-worker.sh
#
# The three required values are printed at the end of 01-master.sh.
# ==============================================================================

set -euo pipefail

# ---- Required variables (must be provided via environment) --------------------
# Using :? causes the script to exit with an error if the variable is unset or empty.
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:?Set CONTROL_PLANE_ENDPOINT to <master-ip>:6443}"
JOIN_TOKEN="${JOIN_TOKEN:?Set JOIN_TOKEN to the token printed by 01-master.sh}"
CA_CERT_HASH="${CA_CERT_HASH:?Set CA_CERT_HASH to the ca-cert-hash printed by 01-master.sh}"

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
log_info "Control-plane endpoint: ${CONTROL_PLANE_ENDPOINT}"
log_info "Join token:             ${JOIN_TOKEN}"
log_info "CA cert hash:           ${CA_CERT_HASH}"
log_info "Worker hostname:        $(hostname)"
log_info "CRI socket:             unix:///var/run/containerd/containerd.sock"

# ==============================================================================
# STEP 1: Validate that 00-common.sh was run
# ==============================================================================
log_section "Step 1 — Pre-flight validation"

# Check containerd is running
if ! systemctl is-active --quiet containerd; then
  log_error "containerd is not running."
  log_error "Please run 00-common.sh on this node first, then retry."
  exit 1
fi
log_ok "containerd is running."

# Check kubeadm is installed
if ! command -v kubeadm >/dev/null 2>&1; then
  log_error "kubeadm not found."
  log_error "Please run 00-common.sh on this node first, then retry."
  exit 1
fi
log_ok "kubeadm is installed: $(kubeadm version -o short)"

# Check that br_netfilter is loaded
if ! lsmod | grep -q "^br_netfilter"; then
  log_error "Kernel module br_netfilter is not loaded."
  log_error "Please run 00-common.sh on this node first, then retry."
  exit 1
fi
log_ok "Kernel module br_netfilter is loaded."

# Check swap is disabled
if swapon --show 2>/dev/null | grep -q .; then
  log_error "Swap is still enabled. Kubelet requires swap to be disabled."
  log_error "Please run 00-common.sh on this node first, then retry."
  exit 1
fi
log_ok "Swap is disabled."

# Check connectivity to the control plane
log_info "Checking connectivity to control plane at ${CONTROL_PLANE_ENDPOINT}..."
MASTER_IP=$(echo "$CONTROL_PLANE_ENDPOINT" | cut -d: -f1)
MASTER_PORT=$(echo "$CONTROL_PLANE_ENDPOINT" | cut -d: -f2)
if ! nc -z -w5 "$MASTER_IP" "$MASTER_PORT" 2>/dev/null; then
  log_error "Cannot reach ${CONTROL_PLANE_ENDPOINT}."
  log_error "Ensure the master node is running and port ${MASTER_PORT} is accessible."
  log_error "Check firewall rules: ufw, iptables, or security groups."
  exit 1
fi
log_ok "Control plane is reachable at ${CONTROL_PLANE_ENDPOINT}."

# ==============================================================================
# STEP 2: kubeadm reset — clean any previous state
# This is important if this node was previously part of a cluster (e.g., during
# re-provisioning). It removes any stale configuration and resets networking.
# ==============================================================================
log_section "Step 2 — Reset previous cluster state (kubeadm reset)"

log_info "Running kubeadm reset to clean any previous configuration..."
kubeadm reset \
  --cri-socket="unix:///var/run/containerd/containerd.sock" \
  --force

# Clean up leftover CNI and networking files from a previous cluster join
log_info "Cleaning up CNI configuration..."
rm -rf /etc/cni/net.d/*
rm -f /etc/kubernetes/kubelet.conf
rm -f /etc/kubernetes/bootstrap-kubelet.conf
rm -f /etc/kubernetes/pki/ca.crt

# Clean up iptables rules left by the previous cluster
log_info "Flushing iptables rules..."
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X || true
ip6tables -F && ip6tables -t nat -F && ip6tables -t mangle -F && ip6tables -X 2>/dev/null || true

# Restart containerd and kubelet to ensure a clean state
log_info "Restarting containerd..."
systemctl restart containerd
log_ok "kubeadm reset complete."

# ==============================================================================
# STEP 3: kubeadm join — join this node to the cluster
# ==============================================================================
log_section "Step 3 — Join the cluster (kubeadm join)"

log_info "Joining cluster at ${CONTROL_PLANE_ENDPOINT}..."
kubeadm join "${CONTROL_PLANE_ENDPOINT}" \
  --token "${JOIN_TOKEN}" \
  --discovery-token-ca-cert-hash "${CA_CERT_HASH}" \
  --cri-socket="unix:///var/run/containerd/containerd.sock" \
  2>&1 | tee /tmp/kubeadm-join.log

log_ok "kubeadm join completed. Output saved to /tmp/kubeadm-join.log"

# ==============================================================================
# STEP 4: Verify the join from the worker's perspective
# ==============================================================================
log_section "Step 4 — Local verification"

# Check kubelet is running
log_info "Checking kubelet status..."
if systemctl is-active --quiet kubelet; then
  log_ok "kubelet is running."
else
  log_warn "kubelet is not running. Check: journalctl -u kubelet -n 50"
fi

# Display kubelet status
systemctl status kubelet --no-pager || true

log_section "Worker join complete"

log_ok "This node has joined the cluster."
echo ""
log_info "To verify from the MASTER node, run:"
echo "  kubectl get nodes -o wide"
echo ""
log_info "The node will show as 'Ready' once:"
echo "  1. The kubelet is running (check above)."
echo "  2. The CNI (Calico) pod is scheduled on this node."
echo "  3. The node passes the control-plane health checks (~1-2 minutes)."
echo ""
log_info "Troubleshooting on this node:"
echo "  journalctl -u kubelet -n 100 --no-pager"
echo "  systemctl status containerd"
echo "  cat /tmp/kubeadm-join.log"
