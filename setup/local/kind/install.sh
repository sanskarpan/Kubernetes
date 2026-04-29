#!/usr/bin/env bash
# ==============================================================================
# install.sh — Idempotent installer for Docker (Linux), KIND, and kubectl
#
# Usage:
#   bash install.sh
#
# Override versions with environment variables:
#   KIND_VERSION=0.29.0 KUBECTL_VERSION=1.32.0 bash install.sh
#
# Supported platforms:
#   - Linux  (amd64 / arm64)
#   - macOS  (amd64 / arm64 / Apple Silicon)
#
# This script is idempotent: it checks whether each tool is already installed
# at the required version before attempting to install or upgrade it.
# ==============================================================================

set -euo pipefail

# ---- Versions (override with env vars) ----------------------------------------
KIND_VERSION="${KIND_VERSION:-0.29.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.32.0}"

# ---- Platform detection -------------------------------------------------------
ARCH="${ARCH:-$(uname -m)}"
OS="${OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

# Normalize architecture names to match download URLs
case "$ARCH" in
  x86_64)  ARCH_KIND="amd64"; ARCH_KUBECTL="amd64" ;;
  aarch64) ARCH_KIND="arm64"; ARCH_KUBECTL="arm64" ;;
  arm64)   ARCH_KIND="arm64"; ARCH_KUBECTL="arm64" ;;
  *)
    echo "[ERROR] Unsupported architecture: $ARCH"
    echo "        Supported: x86_64, aarch64, arm64"
    exit 1
    ;;
esac

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
log_section() { printf "\n${BOLD}=== %s ===${RESET}\n" "$*"; }

# ---- Helper: require a command -----------------------------------------------
require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    log_error "Install '$1' and re-run this script."
    exit 1
  fi
}

# ---- Helper: compare semver (returns 0 if $1 >= $2) --------------------------
version_ge() {
  # Uses sort -V for version comparison
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# ==============================================================================
# SECTION 1: Docker
# ==============================================================================

install_docker() {
  log_section "Docker"

  if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
    log_ok "Docker already installed: $DOCKER_VER"
    return 0
  fi

  if [ "$OS" = "darwin" ]; then
    log_warn "Docker not found on macOS."
    log_warn "Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
    log_warn "Or install with: brew install --cask docker"
    exit 1
  fi

  # Linux: install Docker Engine from the official Docker apt repository
  log_info "Installing Docker Engine on Linux..."
  require curl
  require apt-get 2>/dev/null || { log_error "Non-Debian/Ubuntu Linux detected. Install Docker manually."; exit 1; }

  # Remove old versions
  log_info "Removing old Docker packages if present..."
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  # Install prerequisites
  log_info "Installing Docker prerequisites..."
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  # Add Docker GPG key
  log_info "Adding Docker GPG key..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Add Docker apt repository
  log_info "Adding Docker apt repository..."
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Install Docker Engine
  apt-get update -qq
  apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  # Enable and start Docker
  systemctl enable docker
  systemctl start docker

  # Add current user to the docker group (takes effect on next login)
  if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER"
    log_ok "Added $SUDO_USER to the 'docker' group (re-login required)."
  fi

  log_ok "Docker installed successfully."
}

# ==============================================================================
# SECTION 2: KIND
# ==============================================================================

install_kind() {
  log_section "KIND (Kubernetes in Docker)"

  KIND_URL="https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-${OS}-${ARCH_KIND}"

  if command -v kind >/dev/null 2>&1; then
    INSTALLED_KIND=$(kind version | awk '{print $2}' | tr -d 'v')
    if version_ge "$INSTALLED_KIND" "$KIND_VERSION"; then
      log_ok "KIND already installed: v${INSTALLED_KIND} (required: v${KIND_VERSION})"
      return 0
    else
      log_warn "KIND v${INSTALLED_KIND} is older than required v${KIND_VERSION}. Upgrading..."
    fi
  else
    log_info "KIND not found. Installing v${KIND_VERSION} (${OS}/${ARCH_KIND})..."
  fi

  log_info "Downloading KIND from: $KIND_URL"
  curl -fsSL -o /tmp/kind "$KIND_URL"
  chmod +x /tmp/kind

  if [ "$OS" = "linux" ]; then
    sudo mv /tmp/kind /usr/local/bin/kind
  else
    # macOS — prefer /usr/local/bin or ~/.local/bin
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
      mv /tmp/kind /usr/local/bin/kind
    else
      mkdir -p "$HOME/.local/bin"
      mv /tmp/kind "$HOME/.local/bin/kind"
      log_warn "Installed KIND to ~/.local/bin/kind — ensure this is on your PATH."
    fi
  fi

  log_ok "KIND v${KIND_VERSION} installed at: $(command -v kind)"
}

# ==============================================================================
# SECTION 3: kubectl
# ==============================================================================

install_kubectl() {
  log_section "kubectl"

  KUBECTL_URL="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${ARCH_KUBECTL}/kubectl"

  if command -v kubectl >/dev/null 2>&1; then
    INSTALLED_KUBECTL=$(kubectl version --client --output=json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['clientVersion']['gitVersion'].lstrip('v'))" \
      2>/dev/null || kubectl version --client --short 2>/dev/null | awk '{print $3}' | tr -d 'v')
    if version_ge "$INSTALLED_KUBECTL" "$KUBECTL_VERSION"; then
      log_ok "kubectl already installed: v${INSTALLED_KUBECTL} (required: v${KUBECTL_VERSION})"
      return 0
    else
      log_warn "kubectl v${INSTALLED_KUBECTL} is older than required v${KUBECTL_VERSION}. Upgrading..."
    fi
  else
    log_info "kubectl not found. Installing v${KUBECTL_VERSION} (${OS}/${ARCH_KUBECTL})..."
  fi

  log_info "Downloading kubectl from: $KUBECTL_URL"
  curl -fsSL -o /tmp/kubectl "$KUBECTL_URL"
  chmod +x /tmp/kubectl

  # Verify checksum
  log_info "Verifying kubectl checksum..."
  curl -fsSL -o /tmp/kubectl.sha256 "${KUBECTL_URL}.sha256"
  (cd /tmp && echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check) \
    || { log_error "kubectl checksum verification failed!"; exit 1; }

  if [ "$OS" = "linux" ]; then
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
  else
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
      mv /tmp/kubectl /usr/local/bin/kubectl
    else
      mkdir -p "$HOME/.local/bin"
      mv /tmp/kubectl "$HOME/.local/bin/kubectl"
      log_warn "Installed kubectl to ~/.local/bin/kubectl — ensure this is on your PATH."
    fi
  fi

  log_ok "kubectl v${KUBECTL_VERSION} installed at: $(command -v kubectl)"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
  log_section "kube-platform installer"
  log_info "Platform: ${OS}/${ARCH} (KIND arch: ${ARCH_KIND}, kubectl arch: ${ARCH_KUBECTL})"
  log_info "Versions to install:"
  log_info "  KIND:    v${KIND_VERSION}"
  log_info "  kubectl: v${KUBECTL_VERSION}"
  echo ""

  install_docker
  install_kind
  install_kubectl

  # ---- Summary ---------------------------------------------------------------
  log_section "Installation Summary"

  if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "installed")
    log_ok "docker    : $DOCKER_VER"
  else
    log_warn "docker    : not found (manual install required on macOS)"
  fi

  if command -v kind >/dev/null 2>&1; then
    log_ok "kind      : $(kind version)"
  else
    log_error "kind      : not found"
  fi

  if command -v kubectl >/dev/null 2>&1; then
    log_ok "kubectl   : $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
  else
    log_error "kubectl   : not found"
  fi

  echo ""
  log_ok "All tools installed. Next steps:"
  echo "  1. Ensure Docker is running."
  echo "  2. Create the cluster:"
  echo "       kind create cluster --name kube-platform --config setup/local/kind/kind-config.yml"
  echo "  3. Verify:"
  echo "       kubectl get nodes"
  echo ""
  echo "Or simply run:  make bootstrap"
}

main "$@"
