#!/usr/bin/env bash
# ==============================================================================
# 00-common.sh — Common node setup for ALL Kubernetes nodes (master + workers)
#
# Run this script on EVERY node before running 01-master.sh or 02-worker.sh.
#
# Usage:
#   sudo bash 00-common.sh
#
# Override versions:
#   K8S_VERSION=1.32 K8S_FULL_VERSION=1.32.0 CONTAINERD_VERSION=1.7.24 sudo bash 00-common.sh
#
# Tested on:
#   - Ubuntu 22.04 LTS (Jammy)
#   - Ubuntu 24.04 LTS (Noble)
# ==============================================================================

set -euo pipefail

# ---- Versions (override with env vars) ----------------------------------------
K8S_VERSION="${K8S_VERSION:-1.32}"
K8S_FULL_VERSION="${K8S_FULL_VERSION:-1.32.0}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.24}"

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

# ---- OS check -----------------------------------------------------------------
if [ ! -f /etc/os-release ]; then
  log_error "/etc/os-release not found. This script supports Ubuntu 22.04/24.04 only."
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "$ID" != "ubuntu" ]]; then
  log_warn "This script is designed for Ubuntu. Detected: $ID $VERSION_ID"
  log_warn "Proceeding anyway — adjust package manager commands if needed."
fi

# ==============================================================================
log_section "Configuration"
log_info "Kubernetes version:  ${K8S_FULL_VERSION} (apt track: ${K8S_VERSION})"
log_info "Containerd version:  ${CONTAINERD_VERSION}"
log_info "Hostname:            $(hostname)"
log_info "OS:                  $PRETTY_NAME"

# ==============================================================================
# STEP 1: Disable swap
# Kubelet requires swap to be disabled for stable performance guarantees.
# ==============================================================================
log_section "Step 1 — Disabling swap"

swapoff -a
log_ok "Swap disabled (runtime)."

# Remove swap entries from /etc/fstab to persist across reboots
if grep -qE '^\s*[^#].*\bswap\b' /etc/fstab; then
  sed -i.bak '/\bswap\b/s/^/#/' /etc/fstab
  log_ok "Swap entries commented out in /etc/fstab."
else
  log_info "No swap entries found in /etc/fstab."
fi

# Verify
if swapon --show 2>/dev/null | grep -q .; then
  log_warn "Swap is still active on some device. Check 'swapon --show'."
else
  log_ok "Swap is fully disabled."
fi

# ==============================================================================
# STEP 2: Load required kernel modules
# overlay:       required by containerd for overlay filesystem (container layers)
# br_netfilter:  required for Kubernetes networking (iptables to see bridged traffic)
# ==============================================================================
log_section "Step 2 — Kernel modules"

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
log_ok "Loaded kernel modules: overlay, br_netfilter"

# Verify
for mod in overlay br_netfilter; do
  if lsmod | grep -q "^${mod}"; then
    log_ok "Module loaded: $mod"
  else
    log_error "Failed to load module: $mod"
    exit 1
  fi
done

# ==============================================================================
# STEP 3: Configure sysctl parameters for Kubernetes networking
# net.bridge.bridge-nf-call-iptables:  allow iptables to see bridged IPv4 traffic
# net.bridge.bridge-nf-call-ip6tables: allow iptables to see bridged IPv6 traffic
# net.ipv4.ip_forward:                 enable IP forwarding (required for pod networking)
# ==============================================================================
log_section "Step 3 — sysctl networking parameters"

cat > /etc/sysctl.d/k8s.conf <<'EOF'
# Kubernetes networking requirements
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system
log_ok "sysctl parameters applied."

# Verify key settings
for param in \
  net.bridge.bridge-nf-call-iptables \
  net.bridge.bridge-nf-call-ip6tables \
  net.ipv4.ip_forward; do
  val=$(sysctl -n "$param" 2>/dev/null || echo "not found")
  if [ "$val" = "1" ]; then
    log_ok "$param = 1"
  else
    log_error "$param is not set to 1 (got: $val)"
    exit 1
  fi
done

# ==============================================================================
# STEP 4: Install containerd from the official Docker repository
# We use the Docker repository because it ships newer containerd builds than
# the Ubuntu default repos. The docker packages (docker-ce etc.) are NOT installed.
# ==============================================================================
log_section "Step 4 — Install containerd ${CONTAINERD_VERSION}"

# Install prerequisites
apt-get update -qq
apt-get install -y -qq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common

# Add Docker GPG key
log_info "Adding Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker apt repository
log_info "Adding Docker apt repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq

# Install containerd (pinned version)
CONTAINERD_PKG="containerd.io=${CONTAINERD_VERSION}-*"
log_info "Installing $CONTAINERD_PKG..."
apt-get install -y "$CONTAINERD_PKG" || {
  log_warn "Pinned version not found in repo. Installing latest containerd.io..."
  apt-get install -y containerd.io
}

# ==============================================================================
# STEP 5: Configure containerd
# Key: SystemdCgroup = true — ensures cgroup management is delegated to systemd,
# which is required when running on systems with systemd (all modern Ubuntu versions).
# Without this, kubelet and containerd can fight over cgroup management.
# ==============================================================================
log_section "Step 5 — Configure containerd (SystemdCgroup=true)"

# Generate default config and then patch it
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Set SystemdCgroup = true in the runc runtime section
if grep -q "SystemdCgroup" /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  log_ok "Set SystemdCgroup = true in /etc/containerd/config.toml"
else
  # Inject the setting if it doesn't exist
  sed -i '/\[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options\]/a\            SystemdCgroup = true' \
    /etc/containerd/config.toml
  log_ok "Injected SystemdCgroup = true into /etc/containerd/config.toml"
fi

# Enable and restart containerd
systemctl enable containerd
systemctl restart containerd
log_ok "containerd restarted and enabled."

# Verify containerd is running
if systemctl is-active --quiet containerd; then
  CONTAINERD_VER=$(containerd --version | awk '{print $3}')
  log_ok "containerd is running: $CONTAINERD_VER"
else
  log_error "containerd failed to start."
  journalctl -u containerd -n 20
  exit 1
fi

# ==============================================================================
# STEP 6: Install kubelet, kubeadm, kubectl from the official Kubernetes apt repo
# ==============================================================================
log_section "Step 6 — Install kubelet, kubeadm, kubectl (K8s ${K8S_FULL_VERSION})"

# Add Kubernetes GPG key
log_info "Adding Kubernetes GPG key..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes apt repository
log_info "Adding Kubernetes apt repository (v${K8S_VERSION})..."
echo \
  "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq

# Install kubelet, kubeadm, kubectl
log_info "Installing kubelet kubeadm kubectl..."
apt-get install -y \
  "kubelet=${K8S_FULL_VERSION}-*" \
  "kubeadm=${K8S_FULL_VERSION}-*" \
  "kubectl=${K8S_FULL_VERSION}-*" || {
  log_warn "Pinned version not found. Installing latest available in the ${K8S_VERSION} track..."
  apt-get install -y kubelet kubeadm kubectl
}

# ==============================================================================
# STEP 7: Hold packages to prevent uncontrolled upgrades
# Kubernetes upgrades must be done intentionally (one minor version at a time).
# apt-mark hold prevents apt upgrade from automatically upgrading these packages.
# ==============================================================================
log_section "Step 7 — Holding Kubernetes packages"

apt-mark hold kubelet kubeadm kubectl containerd.io
log_ok "Packages held: kubelet kubeadm kubectl containerd.io"

# Enable kubelet (it will be started by kubeadm init/join)
systemctl enable kubelet
log_ok "kubelet enabled (not started yet — will be started by kubeadm)."

# ==============================================================================
# STEP 8: Verify all components
# ==============================================================================
log_section "Step 8 — Verification"

log_ok "containerd : $(containerd --version)"
log_ok "kubeadm    : $(kubeadm version -o short)"
log_ok "kubelet    : $(kubelet --version)"
log_ok "kubectl    : $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

log_section "Common setup complete"
log_info "Next steps:"
log_info "  On the MASTER node: sudo bash 01-master.sh"
log_info "  On WORKER nodes:    sudo bash 02-worker.sh (after master is initialized)"
