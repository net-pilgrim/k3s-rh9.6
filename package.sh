#!/usr/bin/env bash
# ==============================================================================
# Offline Package Generator for RHEL 9.6 k3s Platform
# Run this script on an internet-connected machine to assemble the complete
# air-gap bundle (binaries, RPMs, container images, installer, and manifests).
#
# Usage:
#   ./package.sh
#   ./package.sh --include-workloads
#   ./package.sh --output /path/to/my-bundle.tar.gz
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

# Default versions and paths
K3S_VERSION="${K3S_VERSION:-v1.37.1+k3s1}"
K3S_VERSION_URL=$(echo "${K3S_VERSION}" | sed 's/+/%2B/g')
HELM_VERSION="${HELM_VERSION:-v3.17.1}"
SELINUX_RPM_URL="https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.latest.1/k3s-selinux-1.6-1.el9.noarch.rpm"
CRANE_VERSION="v0.20.3"

INCLUDE_WORKLOADS=false
OUTPUT_ARCHIVE="${SCRIPT_DIR}/k3s-rh9.6-offline-bundle.tar.gz"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT_ARCHIVE="$2"; shift 2 ;;
        -w|--include-workloads|--include-workload-images)
            INCLUDE_WORKLOADS=true; shift ;;
        -v|--k3s-version)
            K3S_VERSION="$2"; K3S_VERSION_URL=$(echo "${K3S_VERSION}" | sed 's/+/%2B/g'); shift 2 ;;
        -h|--help)
            cat << 'EOF'
Usage: ./package.sh [OPTIONS]

Options:
  -o, --output <FILE>          Target archive filename (default: ./k3s-rh9.6-offline-bundle.tar.gz)
  -w, --include-workloads      Download and bundle all container images for Forgejo, Runner, DinD, Plane, It's a Plan
  -v, --k3s-version <VERSION>  k3s release version (default: v1.37.1+k3s1)
  -h, --help                   Show this help message and exit
EOF
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  ____            _                    ____             _ _     _           
 |  _ \ __ _  ___| | ____ _  __ _  ___| __ ) _   _ _ __| | | __| | ___ _ __ 
 | |_) / _` |/ __| |/ / _` |/ _` |/ _ \  _ \| | | | '__| | |/ _` |/ _ \ '__|
 |  __/ (_| | (__|   < (_| | (_| |  __/ |_) | |_| | |  | | | (_| |  __/ |   
 |_|   \__,_|\___|_|\_\__,_|\__, |\___|____/ \__,_|_|  |_|_|\__,_|\___|_|   
                             |___/                                           
EOF
echo -e " Air-Gap Packaging Tool for RHEL 9.6 k3s Platform${NC}\n"

# Enforce TLS 1.2 on curl
CURL_OPTS="--tlsv1.2 --tls-max 1.2"

BUNDLE_NAME="k3s-rh9.6-bundle"
STAGING_DIR="${SCRIPT_DIR}/${BUNDLE_NAME}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"/{bin,rpms,images,manifests,charts}

# ------------------------------------------------------------------------------
# 1. Download k3s binary & installer script
# ------------------------------------------------------------------------------
log_step "[1/6] Downloading k3s binary (${K3S_VERSION}) and installer script..."
curl ${CURL_OPTS} -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/k3s" -o "${STAGING_DIR}/bin/k3s"
chmod +x "${STAGING_DIR}/bin/k3s"

curl ${CURL_OPTS} -fsSL "https://get.k3s.io" -o "${STAGING_DIR}/k3s-install.sh"
chmod +x "${STAGING_DIR}/k3s-install.sh"
log_success "k3s binary ready."

# ------------------------------------------------------------------------------
# 2. Download k3s core airgap images
# ------------------------------------------------------------------------------
log_step "[2/6] Downloading k3s core container images (Traefik, CoreDNS, Flannel, Metrics)..."
curl ${CURL_OPTS} -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/k3s-airgap-images-amd64.tar.zst" \
    -o "${STAGING_DIR}/images/k3s-airgap-images-amd64.tar.zst"
log_success "k3s core airgap images downloaded."

# ------------------------------------------------------------------------------
# 3. Download k3s-selinux RPM for RHEL 9
# ------------------------------------------------------------------------------
log_step "[3/6] Downloading k3s-selinux RPM policy for RHEL 9.6..."
curl ${CURL_OPTS} -fL "${SELINUX_RPM_URL}" -o "${STAGING_DIR}/rpms/k3s-selinux-1.6-1.el9.noarch.rpm"
log_success "k3s-selinux RPM ready."

# ------------------------------------------------------------------------------
# 4. Download Helm 3 standalone binary & Charts
# ------------------------------------------------------------------------------
log_step "[4/6] Downloading Helm 3 standalone binary (${HELM_VERSION}) and local charts..."
TMP_HELM_DIR=$(mktemp -d -t helm-XXXXXX)
curl ${CURL_OPTS} -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C "${TMP_HELM_DIR}"
mv "${TMP_HELM_DIR}/linux-amd64/helm" "${STAGING_DIR}/bin/helm"
chmod +x "${STAGING_DIR}/bin/helm"
rm -rf "${TMP_HELM_DIR}"

if [ -d "${SCRIPT_DIR}/charts" ]; then
    cp -r "${SCRIPT_DIR}/charts"/* "${STAGING_DIR}/charts/" 2>/dev/null || true
fi
log_success "Helm 3 binary and charts ready."

# ------------------------------------------------------------------------------
# 5. Optional: Download Workload Images (Forgejo, Runner, Plane, It's a Plan)
# ------------------------------------------------------------------------------
if [ "$INCLUDE_WORKLOADS" = true ]; then
    log_step "[5/6] Pulling and packaging workload container images..."
    WORKLOAD_IMAGES=(
        # Cert-Manager v1.17
        "quay.io/jetstack/cert-manager-controller:v1.17.1"
        "quay.io/jetstack/cert-manager-cainjector:v1.17.1"
        "quay.io/jetstack/cert-manager-webhook:v1.17.1"
        "quay.io/jetstack/cert-manager-startupapicheck:v1.17.1"

        # Forgejo & DinD Runner
        "code.forgejo.org/forgejo/forgejo:15.0.10"
        "code.forgejo.org/forgejo/forgejo:10.0.1"
        "code.forgejo.org/forgejo/runner:4.0.1"
        "docker:27-dind"
        "docker:27-cli"
        "node:20-bookworm"
        "alpine:latest"
        "busybox:latest"

        # It's a Plan
        "ghcr.io/croffasia/itsaplan-api:latest"
        "ghcr.io/croffasia/itsaplan-web:latest"
        "ghcr.io/croffasia/itsaplan-worker:latest"
        "ghcr.io/croffasia/itsaplan-bot:latest"
        "postgres:17-alpine"
        "rustfs/rustfs:1.0.0"
        "curlimages/curl:latest"

        # Plane Community Edition
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

    CRANE_BIN=""
    if docker info >/dev/null 2>&1; then
        PULL_TOOL="docker"
    elif command -v podman >/dev/null 2>&1; then
        PULL_TOOL="podman"
    else
        log_info "No container daemon running locally. Downloading standalone 'crane' tool..."
        TMP_CRANE_DIR=$(mktemp -d -t crane-XXXXXX)
        curl ${CURL_OPTS} -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" | tar -xz -C "${TMP_CRANE_DIR}" crane
        CRANE_BIN="${TMP_CRANE_DIR}/crane"
        chmod +x "${CRANE_BIN}"
        PULL_TOOL="crane"
    fi

    log_info "Using '${PULL_TOOL}' to fetch workload images..."
    for img in "${WORKLOAD_IMAGES[@]}"; do
        SAFE_NAME=$(echo "$img" | tr '/:' '_')
        TARGET_TAR="${STAGING_DIR}/images/${SAFE_NAME}.tar"
        log_info "Fetching ${img}..."
        case "$PULL_TOOL" in
            docker)
                docker pull -q "$img"
                docker save "$img" -o "${TARGET_TAR}"
                ;;
            podman)
                podman pull -q "$img"
                podman save "$img" -o "${TARGET_TAR}"
                ;;
            crane)
                "${CRANE_BIN}" pull "$img" "${TARGET_TAR}"
                ;;
        esac
    done
    [ -n "${CRANE_BIN}" ] && rm -rf "$(dirname "${CRANE_BIN}")"
    log_success "Workload images packaged."
else
    log_step "[5/6] Skipping workload images (use --include-workloads to bundle them all)."
fi

# ------------------------------------------------------------------------------
# 6. Assemble Bundle & Compress
# ------------------------------------------------------------------------------
log_step "[6/6] Packaging manifests, offline installer, and creating archive..."
cp "${SCRIPT_DIR}/install-airgap.sh" "${STAGING_DIR}/install.sh"
chmod +x "${STAGING_DIR}/install.sh"
cp "${SCRIPT_DIR}/deploy-workloads.sh" "${STAGING_DIR}/deploy-workloads.sh"
chmod +x "${STAGING_DIR}/deploy-workloads.sh"
cp "${SCRIPT_DIR}/repair-k3s.sh" "${STAGING_DIR}/repair-k3s.sh"
chmod +x "${STAGING_DIR}/repair-k3s.sh"
cp "${SCRIPT_DIR}/download-all-images.sh" "${STAGING_DIR}/download-all-images.sh"
chmod +x "${STAGING_DIR}/download-all-images.sh"
cp "${SCRIPT_DIR}/import-images.sh" "${STAGING_DIR}/import-images.sh"
chmod +x "${STAGING_DIR}/import-images.sh"
cp -r "${SCRIPT_DIR}/manifests"/* "${STAGING_DIR}/manifests/"

cat << 'EOF' > "${STAGING_DIR}/README.md"
# k3s Offline Air-Gap Package for RHEL 9.6

This package contains all binaries, RPM policies, container images, Helm charts, and Kubernetes manifests required to deploy the complete platform on RHEL 9.6 with ZERO internet access.

## Quick Installation on the Air-Gapped Server:

```bash
tar -xzf k3s-rh9.6-offline-bundle.tar.gz
cd k3s-rh9.6-bundle
sudo ./install.sh
```

Or deploy/redeploy workloads directly on an existing cluster:
```bash
sudo ./deploy-workloads.sh
```

## Included in this Bundle:
- `bin/k3s`: Standalone k3s server & agent binary
- `bin/helm`: Standalone Helm 3 binary
- `rpms/k3s-selinux*.rpm`: Pre-downloaded SELinux policy RPM for RHEL 9.6
- `images/`: Core and workload image tarballs for automatic import by containerd
- `charts/`: Offline Helm charts for cert-manager, Forgejo, and Plane CE
- `k3s-install.sh`: Offline-compatible k3s bootstrap installer
- `install.sh`: Fully autonomous 1-step offline installation script
- `deploy-workloads.sh`: Standalone workload deployment engine
- `manifests/`: Declarative manifests for Forgejo, Runner, DinD, Plane, and It's a Plan
EOF

log_info "Compressing archive to: ${OUTPUT_ARCHIVE}..."
tar -czf "${OUTPUT_ARCHIVE}" -C "${SCRIPT_DIR}" "${BUNDLE_NAME}"
rm -rf "${STAGING_DIR}"

ARCHIVE_SIZE=$(du -h "${OUTPUT_ARCHIVE}" | awk '{print $1}')
echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}           🎉 OFFLINE PACKAGE CREATED SUCCESSFULLY! 🎉${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e " Archive Location: ${BOLD}${OUTPUT_ARCHIVE}${NC}"
echo -e " File Size:        ${BOLD}${ARCHIVE_SIZE}${NC}"
echo ""
echo " How to use on your air-gapped RHEL 9.6 server:"
echo "   1. Transfer the archive to the server:"
echo "        scp ${OUTPUT_ARCHIVE} root@<RHEL_IP>:/root/"
echo "   2. Extract and run:"
echo "        tar -xzf $(basename "${OUTPUT_ARCHIVE}")"
echo "        cd ${BUNDLE_NAME}"
echo "        sudo ./install.sh"
echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
