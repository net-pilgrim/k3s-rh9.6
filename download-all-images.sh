#!/usr/bin/env bash
# ==============================================================================
# Complete Workload Image Downloader & Airgap Packager
# Downloads all container images for:
#   - cert-manager v1.17
#   - Forgejo Git Forge & CI/CD Runner (DinD)
#   - Plane Community Edition
#   - It's a Plan (itsaplan.dev)
#
# Can run directly on the host (if online/proxied) to import images into k3s,
# or on an external internet-connected machine to create an air-gap transfer bundle.
#
# Usage:
#   ./download-all-images.sh                     # Downloads to ./workload-images/
#   sudo ./download-all-images.sh --import       # Downloads AND imports into local k3s
#   ./download-all-images.sh --archive           # Downloads and builds workload-images.tar.gz
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

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

OUTPUT_DIR="${SCRIPT_DIR}/workload-images"
DO_IMPORT=false
DO_ARCHIVE=false
CRANE_VERSION="v0.20.3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --import)
            DO_IMPORT=true; shift ;;
        --archive)
            DO_ARCHIVE=true; shift ;;
        -o|--output)
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            cat << 'EOF'
Usage: ./download-all-images.sh [OPTIONS]

Options:
  --import           Automatically import images into local k3s containerd
  --archive          Create compressed workload-images.tar.gz for transfer
  -o, --output <DIR> Directory to save image tar files (default: ./workload-images)
  -h, --help         Show this help message and exit
EOF
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  ___                               ____                      _                 _ 
 |_ _|_ __ ___   __ _  __ _  ___   |  _ \  _____      ___ __ | | ___   __ _  __| |
  | || '_ ` _ \ / _` |/ _` |/ _ \  | | | |/ _ \ \ /\ / / '_ \| |/ _ \ / _` |/ _` |
  | || | | | | | (_| | (_| |  __/  | |_| | (_) \ V  V /| | | | | (_) | (_| | (_| |
 |___|_| |_| |_|\__,_|\__, |\___|  |____/ \___/ \_/\_/ |_| |_|_|\___/ \__,_|\__,_|
                      |___/                                                       
EOF
echo -e " Workload Container Image Fetcher (Forgejo, Runner, Plane, It's a Plan)${NC}\n"

mkdir -p "${OUTPUT_DIR}"

# Complete Inventory of all Workload Images
IMAGES=(
    # --- Cert-Manager v1.17 ---
    "quay.io/jetstack/cert-manager-cainjector:v1.17.1"
    "quay.io/jetstack/cert-manager-controller:v1.17.1"
    "quay.io/jetstack/cert-manager-webhook:v1.17.1"
    "quay.io/jetstack/cert-manager-startupapicheck:v1.17.1"

    # --- Forgejo Git Server & CI/CD Runner ---
    "code.forgejo.org/forgejo/forgejo:15.0.10"
    "code.forgejo.org/forgejo/forgejo:10.0.1"
    "code.forgejo.org/forgejo/runner:4.0.1"
    "docker:27-dind"
    "docker:27-cli"
    "node:20-bookworm"
    "alpine:latest"
    "busybox:latest"

    # --- It's a Plan (itsaplan.dev) ---
    "ghcr.io/croffasia/itsaplan-api:latest"
    "ghcr.io/croffasia/itsaplan-web:latest"
    "ghcr.io/croffasia/itsaplan-worker:latest"
    "ghcr.io/croffasia/itsaplan-bot:latest"
    "postgres:17-alpine"
    "rustfs/rustfs:1.0.0"
    "curlimages/curl:latest"

    # --- Plane Community Edition (plane.so) ---
    "artifacts.plane.so/makeplane/plane-frontend:v2.6.3"
    "artifacts.plane.so/makeplane/plane-space:v2.6.3"
    "artifacts.plane.so/makeplane/plane-admin:v2.6.3"
    "artifacts.plane.so/makeplane/plane-live:v2.6.3"
    "artifacts.plane.so/makeplane/plane-backend:v2.6.3"
    "makeplane/plane-frontend:v2.6.3"
    "makeplane/plane-space:v2.6.3"
    "makeplane/plane-admin:v2.6.3"
    "makeplane/plane-backend:v2.6.3"
    "valkey/valkey:7.2.11-alpine"
    "postgres:15.7-alpine"
    "rabbitmq:3.13.6-management-alpine"
    "docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z"
    "redis:7-alpine"
    "rabbitmq:3-management-alpine"
    "minio/minio:RELEASE.2023-09-07T02-17-04Z"
)

# ------------------------------------------------------------------------------
# 1. Determine Image Pull Tool
# ------------------------------------------------------------------------------
log_step "[1/3] Determining Container Image Pull Tool..."
CRANE_BIN=""
PULL_TOOL=""

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    PULL_TOOL="docker"
    log_info "Using local Docker daemon"
elif command -v podman >/dev/null 2>&1; then
    PULL_TOOL="podman"
    log_info "Using local Podman engine"
elif command -v crane >/dev/null 2>&1; then
    CRANE_BIN=$(command -v crane)
    PULL_TOOL="crane"
    log_info "Using installed crane binary: ${CRANE_BIN}"
else
    log_info "Downloading standalone 'crane' tool (lightweight OCI image puller)..."
    TMP_CRANE_DIR=$(mktemp -d -t crane-tool-XXXXXX)
    curl --tlsv1.2 --tls-max 1.2 -fsSL \
        "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C "${TMP_CRANE_DIR}" crane
    CRANE_BIN="${TMP_CRANE_DIR}/crane"
    chmod +x "${CRANE_BIN}"
    PULL_TOOL="crane"
    log_success "crane ${CRANE_VERSION} ready."
fi

# ------------------------------------------------------------------------------
# 2. Download Images to Local Tarballs
# ------------------------------------------------------------------------------
log_step "[2/3] Downloading ${#IMAGES[@]} Container Images to ${OUTPUT_DIR}..."

COUNT=0
TOTAL=${#IMAGES[@]}

for img in "${IMAGES[@]}"; do
    COUNT=$((COUNT + 1))
    SAFE_NAME=$(echo "$img" | tr '/:' '_')
    TARGET_TAR="${OUTPUT_DIR}/${SAFE_NAME}.tar"

    if [ -s "${TARGET_TAR}" ]; then
        log_info "[${COUNT}/${TOTAL}] Already downloaded: ${img}"
        continue
    fi

    log_info "[${COUNT}/${TOTAL}] Pulling: ${img}..."
    case "$PULL_TOOL" in
        docker)
            docker pull -q "$img" 2>/dev/null || true
            docker save "$img" -o "${TARGET_TAR}" 2>/dev/null || rm -f "${TARGET_TAR}"
            ;;
        podman)
            podman pull -q "$img" 2>/dev/null || true
            podman save "$img" -o "${TARGET_TAR}" 2>/dev/null || rm -f "${TARGET_TAR}"
            ;;
        crane)
            "${CRANE_BIN}" pull "$img" "${TARGET_TAR}" 2>/dev/null || rm -f "${TARGET_TAR}"
            ;;
    esac

    if [ -s "${TARGET_TAR}" ]; then
        SIZE=$(du -h "${TARGET_TAR}" | awk '{print $1}')
        log_success "Saved ${img} (${SIZE})"
    else
        log_warn "Failed or skipped: ${img}"
    fi
done

# Clean up temp crane if downloaded
if [ -n "${CRANE_BIN}" ] && [[ "${CRANE_BIN}" == /tmp/* ]]; then
    rm -rf "$(dirname "${CRANE_BIN}")"
fi

# ------------------------------------------------------------------------------
# 3. Optional: Import directly into local k3s
# ------------------------------------------------------------------------------
if [ "$DO_IMPORT" = true ] || ([ "${EUID:-$(id -u)}" -eq 0 ] && [ -x /usr/local/bin/k3s ] && [ "$DO_ARCHIVE" = false ]); then
    log_step "[3/3] Importing Downloaded Images into k3s containerd..."
    mkdir -p /var/lib/rancher/k3s/agent/images

    for tarfile in "${OUTPUT_DIR}"/*.tar; do
        if [ -f "${tarfile}" ]; then
            NAME=$(basename "${tarfile}")
            log_info "Importing ${NAME}..."
            # Copy to persistent k3s image folder for reboot resilience
            cp -n "${tarfile}" /var/lib/rancher/k3s/agent/images/ 2>/dev/null || true
            # Import directly into running containerd
            /usr/local/bin/k3s ctr images import "${tarfile}" >/dev/null 2>&1 || true
        fi
    done

    # Restart failing pods so they pull from local cache
    log_info "Restarting pods currently waiting on images..."
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
        kubectl delete pods --all -n "$ns" --field-selector status.phase=Pending 2>/dev/null || true
    done

    log_success "All images imported into containerd. Pods are refreshing!"
elif [ "$DO_ARCHIVE" = true ]; then
    log_step "[3/3] Creating Compressed Archive workload-images.tar.gz..."
    ARCHIVE_FILE="${SCRIPT_DIR}/workload-images.tar.gz"
    tar -czf "${ARCHIVE_FILE}" -C "${SCRIPT_DIR}" "$(basename "${OUTPUT_DIR}")"
    log_success "Air-gap transfer bundle created: ${ARCHIVE_FILE} ($(du -h "${ARCHIVE_FILE}" | awk '{print $1}'))"
    echo ""
    echo "To install on your air-gapped machine:"
    echo "  1. Copy '${ARCHIVE_FILE}' to the target machine"
    echo "  2. Run: sudo ./import-images.sh ${ARCHIVE_FILE}"
else
    log_step "[3/3] Download Finished."
    echo ""
    echo "Images saved in: ${OUTPUT_DIR}"
    echo "To import into local k3s:  sudo ./import-images.sh ${OUTPUT_DIR}"
fi
