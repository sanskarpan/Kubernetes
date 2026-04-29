#!/usr/bin/env bash
# ==============================================================================
# install.sh — Idempotent installer for minikube and kubectl
#
# Usage:
#   bash install.sh
#
# Override versions with environment variables:
#   MINIKUBE_VERSION=1.34.0 KUBECTL_VERSION=1.32.0 bash install.sh
#
# Supported platforms:
#   - Linux  (amd64 / arm64)
#   - macOS  (amd64 / arm64 / Apple Silicon)
#
# This script is idempotent: it checks whether each tool is already installed
# at the required version before attempting to install or upgrade it.
#
# Prerequisites:
#   - Docker Desktop (macOS) or Docker Engine (Linux) must be running.
#     Install Docker Desktop: https://www.docker.com/products/docker-desktop/
# ==============================================================================

set -euo pipefail

# ---- Versions (override with env vars) ----------------------------------------
MINIKUBE_VERSION="${MINIKUBE_VERSION:-1.34.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.32.0}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.32.0}"

# ---- Minikube start configuration --------------------------------------------
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_ADDONS="${MINIKUBE_ADDONS:-ingress,metrics-server}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-kube-platform}"

# ---- Platform detection -------------------------------------------------------
ARCH="${ARCH:-$(uname -m)}"
OS_RAW="${OS_RAW:-$(uname -s)}"
OS="$(echo "$OS_RAW" | tr '[:upper:]' '[:lower:]')"

# Normalize architecture names to match download URLs
case "$ARCH" in
  x86_64)  ARCH_NORM="amd64" ;;
  aarch64) ARCH_NORM="arm64" ;;
  arm64)   ARCH_NORM="arm64" ;;
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
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# ---- Helper: install a binary from a URL to /usr/local/bin or ~/.local/bin ---
install_binary() {
  local name="$1"
  local url="$2"
  local tmp_path="/tmp/${name}"

  log_info "Downloading ${name} from: ${url}"
  curl -fsSL -o "${tmp_path}" "${url}"
  chmod +x "${tmp_path}"

  if [ "$OS" = "linux" ]; then
    sudo mv "${tmp_path}" "/usr/local/bin/${name}"
  else
    # macOS
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
      mv "${tmp_path}" "/usr/local/bin/${name}"
    else
      mkdir -p "$HOME/.local/bin"
      mv "${tmp_path}" "$HOME/.local/bin/${name}"
      log_warn "Installed ${name} to ~/.local/bin/${name} — ensure this is on your PATH."
    fi
  fi

  log_ok "${name} installed at: $(command -v "${name}")"
}

# ==============================================================================
# SECTION 1: Docker (prerequisite check)
# ==============================================================================

check_docker() {
  log_section "Docker (prerequisite check)"

  if ! command -v docker >/dev/null 2>&1; then
    if [ "$OS" = "darwin" ]; then
      log_error "Docker not found. Install Docker Desktop:"
      log_error "  https://www.docker.com/products/docker-desktop/"
      log_error "  brew install --cask docker"
    else
      log_error "Docker not found. Install Docker Engine:"
      log_error "  https://docs.docker.com/engine/install/"
    fi
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    log_error "Docker is installed but not running."
    log_error "Start Docker Desktop (macOS/Windows) or: sudo systemctl start docker (Linux)"
    exit 1
  fi

  DOCKER_VER=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "unknown")
  log_ok "Docker is running: v${DOCKER_VER}"
}

# ==============================================================================
# SECTION 2: minikube
# ==============================================================================

install_minikube() {
  log_section "minikube"

  # Build the download URL for the current OS and architecture.
  # minikube releases: https://github.com/kubernetes/minikube/releases
  if [ "$OS" = "darwin" ]; then
    MINIKUBE_URL="https://github.com/kubernetes/minikube/releases/download/v${MINIKUBE_VERSION}/minikube-darwin-${ARCH_NORM}"
  else
    MINIKUBE_URL="https://github.com/kubernetes/minikube/releases/download/v${MINIKUBE_VERSION}/minikube-linux-${ARCH_NORM}"
  fi

  if command -v minikube >/dev/null 2>&1; then
    INSTALLED_MINIKUBE=$(minikube version --short 2>/dev/null | tr -d 'v' || echo "0.0.0")
    if version_ge "$INSTALLED_MINIKUBE" "$MINIKUBE_VERSION"; then
      log_ok "minikube already installed: v${INSTALLED_MINIKUBE} (required: v${MINIKUBE_VERSION})"
      return 0
    else
      log_warn "minikube v${INSTALLED_MINIKUBE} is older than required v${MINIKUBE_VERSION}. Upgrading..."
    fi
  else
    log_info "minikube not found. Installing v${MINIKUBE_VERSION} (${OS}/${ARCH_NORM})..."
  fi

  install_binary "minikube" "$MINIKUBE_URL"
}

# ==============================================================================
# SECTION 3: kubectl
# ==============================================================================

install_kubectl() {
  log_section "kubectl"

  KUBECTL_URL="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/${OS}/${ARCH_NORM}/kubectl"

  if command -v kubectl >/dev/null 2>&1; then
    INSTALLED_KUBECTL=$(kubectl version --client --output=json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['clientVersion']['gitVersion'].lstrip('v'))" \
      2>/dev/null || echo "0.0.0")
    if version_ge "$INSTALLED_KUBECTL" "$KUBECTL_VERSION"; then
      log_ok "kubectl already installed: v${INSTALLED_KUBECTL} (required: v${KUBECTL_VERSION})"
      return 0
    else
      log_warn "kubectl v${INSTALLED_KUBECTL} is older than required v${KUBECTL_VERSION}. Upgrading..."
    fi
  else
    log_info "kubectl not found. Installing v${KUBECTL_VERSION} (${OS}/${ARCH_NORM})..."
  fi

  log_info "Downloading kubectl from: ${KUBECTL_URL}"
  curl -fsSL -o /tmp/kubectl "$KUBECTL_URL"
  chmod +x /tmp/kubectl

  # Verify checksum
  log_info "Verifying kubectl checksum..."
  curl -fsSL -o /tmp/kubectl.sha256 "${KUBECTL_URL}.sha256"
  (cd /tmp && echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check) \
    || { log_error "kubectl checksum verification FAILED. Aborting."; exit 1; }

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
# SECTION 4: Start minikube cluster
# ==============================================================================

start_minikube() {
  log_section "Starting minikube cluster"

  # Check if the profile already exists and is running.
  if minikube status --profile="${MINIKUBE_PROFILE}" >/dev/null 2>&1; then
    MINIKUBE_STATUS=$(minikube status --profile="${MINIKUBE_PROFILE}" --format='{{.Host}}' 2>/dev/null || echo "Unknown")
    if [ "$MINIKUBE_STATUS" = "Running" ]; then
      log_ok "minikube profile '${MINIKUBE_PROFILE}' is already running."
      return 0
    else
      log_warn "minikube profile '${MINIKUBE_PROFILE}' exists but is not running. Starting..."
      minikube start --profile="${MINIKUBE_PROFILE}"
      return 0
    fi
  fi

  log_info "Creating minikube cluster with profile '${MINIKUBE_PROFILE}'..."
  log_info "Configuration:"
  log_info "  Driver:      ${MINIKUBE_DRIVER}"
  log_info "  CPUs:        ${MINIKUBE_CPUS}"
  log_info "  Memory:      ${MINIKUBE_MEMORY}MB"
  log_info "  Kubernetes:  ${KUBERNETES_VERSION}"
  log_info "  Addons:      ${MINIKUBE_ADDONS}"

  minikube start \
    --profile="${MINIKUBE_PROFILE}" \
    --driver="${MINIKUBE_DRIVER}" \
    --cpus="${MINIKUBE_CPUS}" \
    --memory="${MINIKUBE_MEMORY}" \
    --kubernetes-version="${KUBERNETES_VERSION}" \
    --addons="${MINIKUBE_ADDONS}"

  log_ok "minikube cluster '${MINIKUBE_PROFILE}' started successfully."
}

# ==============================================================================
# SECTION 5: Configure kubectl context
# ==============================================================================

configure_kubectl() {
  log_section "Configuring kubectl context"

  # minikube automatically sets the kubectl context when it starts.
  # Verify the context is set correctly.
  CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")

  if [ "$CURRENT_CONTEXT" = "${MINIKUBE_PROFILE}" ]; then
    log_ok "kubectl context is already set to '${MINIKUBE_PROFILE}'."
  else
    log_info "Setting kubectl context to '${MINIKUBE_PROFILE}'..."
    kubectl config use-context "${MINIKUBE_PROFILE}"
    log_ok "kubectl context set to '${MINIKUBE_PROFILE}'."
  fi
}

# ==============================================================================
# SECTION 6: Verify cluster is ready
# ==============================================================================

verify_cluster() {
  log_section "Verifying cluster readiness"

  log_info "Waiting for all nodes to be Ready (timeout: 120s)..."
  kubectl wait --for=condition=Ready nodes --all --timeout=120s

  log_info "Cluster nodes:"
  kubectl get nodes -o wide

  log_info "Waiting for core system pods to be Running..."
  kubectl wait --for=condition=Ready pods \
    --all \
    --namespace=kube-system \
    --timeout=120s \
    2>/dev/null || log_warn "Some kube-system pods are not yet Ready — this may be normal during startup."

  # Verify the ingress addon if enabled
  if echo "${MINIKUBE_ADDONS}" | grep -q "ingress"; then
    log_info "Waiting for ingress-nginx controller..."
    kubectl wait --for=condition=Ready pods \
      --all \
      --namespace=ingress-nginx \
      --timeout=120s \
      2>/dev/null || log_warn "ingress-nginx pods are not yet Ready."
  fi

  log_ok "Cluster is ready."
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
  log_section "kube-platform minikube installer"
  log_info "Platform: ${OS}/${ARCH} (normalized: ${ARCH_NORM})"
  log_info "Versions to install:"
  log_info "  minikube:   v${MINIKUBE_VERSION}"
  log_info "  kubectl:    v${KUBECTL_VERSION}"
  log_info "  Kubernetes: ${KUBERNETES_VERSION}"
  echo ""

  check_docker
  install_minikube
  install_kubectl
  start_minikube
  configure_kubectl
  verify_cluster

  # ---- Summary ---------------------------------------------------------------
  log_section "Installation Summary"

  if command -v minikube >/dev/null 2>&1; then
    log_ok "minikube  : $(minikube version --short)"
  else
    log_error "minikube  : not found"
  fi

  if command -v kubectl >/dev/null 2>&1; then
    log_ok "kubectl   : $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
  else
    log_error "kubectl   : not found"
  fi

  if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "installed")
    log_ok "docker    : v${DOCKER_VER}"
  fi

  echo ""
  log_ok "minikube cluster '${MINIKUBE_PROFILE}' is running. Next steps:"
  echo ""
  echo "  1. Verify the cluster:"
  echo "       kubectl get nodes"
  echo "       kubectl get pods --all-namespaces"
  echo ""
  echo "  2. Access the minikube dashboard:"
  echo "       minikube dashboard --profile=${MINIKUBE_PROFILE}"
  echo ""
  echo "  3. Get the minikube IP (for ingress):"
  echo "       minikube ip --profile=${MINIKUBE_PROFILE}"
  echo ""
  echo "  4. Deploy this repo's manifests:"
  echo "       kubectl apply -k core/"
  echo ""
  echo "  5. Deploy with Helm:"
  echo "       helm install apache ./helm/apache -n web --create-namespace"
  echo "       helm install node-app ./helm/node-app -n api --create-namespace"
  echo "       helm install mysql ./helm/mysql -n data --create-namespace"
  echo ""
  echo "  6. Or deploy all with helmfile:"
  echo "       helmfile sync"
  echo ""
  echo "  7. Stop the cluster when done:"
  echo "       minikube stop --profile=${MINIKUBE_PROFILE}"
  echo ""
  echo "Or simply run:  make bootstrap"
}

main "$@"
