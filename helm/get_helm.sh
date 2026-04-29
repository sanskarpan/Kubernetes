#!/usr/bin/env bash
# get_helm.sh — Simplified Helm installer for Linux and macOS
#
# Usage:
#   ./get_helm.sh                       # Install default version
#   HELM_VERSION=3.16.0 ./get_helm.sh  # Install specific version
#
# The official installer is at:
#   https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
#
# This script:
#   1. Detects OS and CPU architecture
#   2. Downloads the Helm binary archive from get.helm.sh
#   3. Verifies the SHA-256 checksum
#   4. Installs the binary to /usr/local/bin/helm

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HELM_VERSION="${HELM_VERSION:-3.17.0}"
INSTALL_DIR="${HELM_INSTALL_DIR:-/usr/local/bin}"

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

case "${OS}" in
  linux)   OS="linux"   ;;
  darwin)  OS="darwin"  ;;
  *)
    echo "ERROR: Unsupported operating system: ${OS}"
    echo "       Supported: linux, darwin"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Detect CPU architecture
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"

case "${ARCH}" in
  x86_64)          ARCH="amd64"  ;;
  aarch64|arm64)   ARCH="arm64"  ;;
  armv7l)          ARCH="arm"    ;;
  i386|i686)       ARCH="386"    ;;
  *)
    echo "ERROR: Unsupported architecture: ${ARCH}"
    echo "       Supported: x86_64, aarch64/arm64, armv7l, i386/i686"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Construct download URLs
# ---------------------------------------------------------------------------
PACKAGE_NAME="helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
BASE_URL="https://get.helm.sh"
URL="${BASE_URL}/${PACKAGE_NAME}"
CHECKSUM_URL="${URL}.sha256sum"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT   # Always clean up temp dir on exit

# ---------------------------------------------------------------------------
# Check for required tools
# ---------------------------------------------------------------------------
for cmd in curl sha256sum tar; do
  if ! command -v "${cmd}" &>/dev/null; then
    # On macOS, sha256sum is provided by 'shasum -a 256'
    if [[ "${cmd}" == "sha256sum" && "$(uname -s)" == "Darwin" ]]; then
      : # handled below
    else
      echo "ERROR: Required command not found: ${cmd}"
      exit 1
    fi
  fi
done

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Helm Installer"
echo "  Version : v${HELM_VERSION}"
echo "  OS      : ${OS}"
echo "  Arch    : ${ARCH}"
echo "  URL     : ${URL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Downloading Helm archive..."
curl -fsSL "${URL}" -o "${TMP_DIR}/helm.tar.gz"

echo "Downloading checksum file..."
curl -fsSL "${CHECKSUM_URL}" -o "${TMP_DIR}/helm.tar.gz.sha256sum"

# ---------------------------------------------------------------------------
# Verify checksum
# ---------------------------------------------------------------------------
echo "Verifying SHA-256 checksum..."

# Normalise checksum file: the downloaded file contains an absolute path
# like "./linux-amd64/helm.tar.gz"; we need to match against our local path.
# Extract only the hash, then compare manually for portability.
EXPECTED_HASH="$(awk '{print $1}' "${TMP_DIR}/helm.tar.gz.sha256sum")"
ACTUAL_HASH="$(sha256sum "${TMP_DIR}/helm.tar.gz" 2>/dev/null | awk '{print $1}' \
               || shasum -a 256 "${TMP_DIR}/helm.tar.gz" | awk '{print $1}')"

if [[ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]]; then
  echo "ERROR: Checksum verification failed!"
  echo "  Expected : ${EXPECTED_HASH}"
  echo "  Actual   : ${ACTUAL_HASH}"
  echo "  The downloaded file may be corrupt or tampered with."
  exit 1
fi

echo "Checksum verified: ${ACTUAL_HASH}"

# ---------------------------------------------------------------------------
# Extract and install
# ---------------------------------------------------------------------------
echo "Extracting archive..."
tar -xzf "${TMP_DIR}/helm.tar.gz" -C "${TMP_DIR}"

HELM_BINARY="${TMP_DIR}/${OS}-${ARCH}/helm"

if [[ ! -f "${HELM_BINARY}" ]]; then
  echo "ERROR: Helm binary not found at expected path: ${HELM_BINARY}"
  exit 1
fi

echo "Installing Helm to ${INSTALL_DIR}/helm..."

# Use sudo if the install directory is not writable by the current user
if [[ -w "${INSTALL_DIR}" ]]; then
  mv "${HELM_BINARY}" "${INSTALL_DIR}/helm"
  chmod +x "${INSTALL_DIR}/helm"
else
  sudo mv "${HELM_BINARY}" "${INSTALL_DIR}/helm"
  sudo chmod +x "${INSTALL_DIR}/helm"
fi

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------
if ! command -v helm &>/dev/null; then
  echo ""
  echo "WARNING: helm is not on your PATH."
  echo "  Add ${INSTALL_DIR} to your PATH, e.g.:"
  echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
else
  echo ""
  helm version
  echo ""
  echo "Helm installed successfully."
fi

# ---------------------------------------------------------------------------
# Post-install hints
# ---------------------------------------------------------------------------
cat <<'EOF'

Next steps:
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo update
  helm search repo bitnami

Documentation:
  https://helm.sh/docs/

EOF
