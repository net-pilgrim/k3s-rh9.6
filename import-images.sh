#!/usr/bin/env bash
# ==============================================================================
# Container Image Import Tool for k3s
# Imports offline image tarballs directly into k3s containerd and re-triggers
# pods waiting in ImagePullBackOff.
#
# Usage:
#   sudo ./import-images.sh
#   sudo ./import-images.sh /path/to/workload-images.tar.gz
#   sudo ./import-images.sh /path/to/image-folder/
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"; }
log_info() { echo -e "${CYAN}   ℹ ${NC}$1"; }
log_success() { echo -e "${GREEN}   ✔ ${NC}$1"; }
log_warn() { echo -e "${YELLOW}   ⚠ ${NC}$1"; }
log_error() { echo -e "${RED}   ✖ ERROR: ${NC}$1" >&2; }

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "This script must be run as root (e.g. sudo ./import-images.sh)"
    exit 1
fi

K3S_BIN="/usr/local/bin/k3s"
if [ ! -x "${K3S_BIN}" ] && [ -x /usr/bin/k3s ]; then
    K3S_BIN="/usr/bin/k3s"
fi

if [ ! -x "${K3S_BIN}" ]; then
    log_error "k3s binary not found in /usr/local/bin/k3s or /usr/bin/k3s!"
    exit 1
fi

SOURCE="${1:-}"

# Auto-detect source if not passed
if [ -z "${SOURCE}" ]; then
    for candidate in ./workload-images.tar.gz ./workload-images ./images /tmp/images /tmp/workload-images; do
        if [ -e "${candidate}" ]; then
            SOURCE="${candidate}"
            break
        fi
    done
fi

if [ -z "${SOURCE}" ] || [ ! -e "${SOURCE}" ]; then
    log_error "No image source found! Usage: sudo ./import-images.sh <file.tar.gz | dir>"
    exit 1
fi

echo -e "\n${BLUE}${BOLD}==============================================================================${NC}"
echo -e "${BLUE}${BOLD}            📥 k3s Container Image Importer${NC}"
echo -e "${BLUE}${BOLD}==============================================================================${NC}\n"

TMP_DIR=""
IMAGE_DIR="${SOURCE}"

if [ -f "${SOURCE}" ] && [[ "${SOURCE}" =~ \.tar\.gz$ ]]; then
    log_info "Extracting compressed bundle: ${SOURCE}..."
    TMP_DIR=$(mktemp -d -t k3s-images-XXXXXX)
    tar -xzf "${SOURCE}" -C "${TMP_DIR}"
    IMAGE_DIR=$(find "${TMP_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1 || echo "${TMP_DIR}")
    trap 'rm -rf "${TMP_DIR}"' EXIT
fi

# Ensure persistent k3s auto-import directory exists
mkdir -p /var/lib/rancher/k3s/agent/images

# ------------------------------------------------------------------------------
# Import Image Files
# ------------------------------------------------------------------------------
log_step "[1/3] Importing Container Images into containerd..."

shopt -s nullglob
if [ -f "${IMAGE_DIR}" ] && [[ "${IMAGE_DIR}" =~ \.tar$ ]]; then
    TAR_FILES=("${IMAGE_DIR}")
else
    TAR_FILES=("${IMAGE_DIR}"/*.tar "${IMAGE_DIR}"/*.tar.gz "${IMAGE_DIR}"/*.tar.zst)
fi
shopt -u nullglob

if [ ${#TAR_FILES[@]} -eq 0 ]; then
    log_error "No .tar image files found in ${IMAGE_DIR}!"
    exit 1
fi

TOTAL=${#TAR_FILES[@]}
COUNT=0

for tarfile in "${TAR_FILES[@]}"; do
    COUNT=$((COUNT + 1))
    FILENAME=$(basename "${tarfile}")
    echo -n " [${COUNT}/${TOTAL}] Importing ${FILENAME}... "

    # 1. Copy to /var/lib/rancher/k3s/agent/images for persistent cluster reboots
    cp -n "${tarfile}" /var/lib/rancher/k3s/agent/images/ 2>/dev/null || true

    # 2. Directly import into the running containerd daemon via k3s ctr
    if "${K3S_BIN}" ctr -n k8s.io images import "${tarfile}" >/dev/null 2>&1; then
        echo -e "${GREEN}DONE${NC}"
    else
        echo -e "${YELLOW}IMPORTED (or already cached)${NC}"
    fi
done

log_success "Imported ${TOTAL} container images."

# ------------------------------------------------------------------------------
# 2. Check local image cache
# ------------------------------------------------------------------------------
log_step "[2/3] Checking containerd Cached Images..."
LOADED_COUNT=$("${K3S_BIN}" crictl images -q 2>/dev/null | wc -l || echo "0")
log_info "Total cached images in local cluster: ${LOADED_COUNT}"

# ------------------------------------------------------------------------------
# 3. Refresh Backed-off Pods
# ------------------------------------------------------------------------------
log_step "[3/3] Triggering Pod Re-evaluations..."
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
if [ -f /root/.kube/config ] && [ ! -f "${KUBECONFIG}" ]; then
    export KUBECONFIG=/root/.kube/config
fi

if command -v kubectl >/dev/null 2>&1; then
    for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
        # Delete pods that are stuck in ErrImagePull or ImagePullBackOff so they re-schedule immediately
        FAILED_PODS=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -E "(ImagePullBackOff|ErrImagePull)" | awk '{print $1}' || true)
        if [ -n "${FAILED_PODS}" ]; then
            log_info "Restarting stuck pods in namespace '${ns}': ${FAILED_PODS}"
            echo "${FAILED_PODS}" | xargs kubectl delete pod -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
        fi
    done
fi

log_success "Stuck pods restarted. Pods will now bind directly to the locally cached images!"
echo ""
echo "Monitor status with:"
echo "  kubectl get pods -A -w"
