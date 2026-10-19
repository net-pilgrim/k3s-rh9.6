#!/usr/bin/env bash
# ==============================================================================
# Build Standalone Air-Gap Bundle for RHEL 9.6 / Linux
# Run this script on a machine WITH internet access to prepare the offline package.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"
K3S_VERSION_URL=$(echo "${K3S_VERSION}" | sed 's/+/%2B/g')
HELM_VERSION="${HELM_VERSION:-v3.17.1}"
SELINUX_RPM_URL="https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.latest.1/k3s-selinux-1.6-1.el9.noarch.rpm"

BUNDLE_NAME="k3s-airgap-rhel9-bundle"
OUTPUT_DIR="${PROJECT_ROOT}/${BUNDLE_NAME}"
ARCHIVE_FILE="${PROJECT_ROOT}/${BUNDLE_NAME}.tar.gz"

echo "=============================================================================="
echo "        Building Air-Gap Installation Bundle for RHEL 9.6"
echo "=============================================================================="
echo "Target k3s Version: ${K3S_VERSION}"
echo "Target Helm Version: ${HELM_VERSION}"
echo "Output Directory:   ${OUTPUT_DIR}"
echo "=============================================================================="

rm -rf "${OUTPUT_DIR}" "${ARCHIVE_FILE}"
mkdir -p "${OUTPUT_DIR}"/{bin,rpms,images,manifests,scripts}

echo "--> [1/5] Downloading k3s binary and installer script..."
curl -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/k3s" -o "${OUTPUT_DIR}/bin/k3s"
chmod +x "${OUTPUT_DIR}/bin/k3s"
curl -fsSL "https://get.k3s.io" -o "${OUTPUT_DIR}/k3s-install.sh"
chmod +x "${OUTPUT_DIR}/k3s-install.sh"

echo "--> [2/5] Downloading k3s air-gap core container images..."
curl -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION_URL}/k3s-airgap-images-amd64.tar.zst" \
    -o "${OUTPUT_DIR}/images/k3s-airgap-images-amd64.tar.zst"

echo "--> [3/5] Downloading k3s-selinux RPM for RHEL 9..."
curl -fL "${SELINUX_RPM_URL}" -o "${OUTPUT_DIR}/rpms/k3s-selinux-1.6-1.el9.noarch.rpm"

echo "--> [4/5] Downloading Helm 3 standalone binary..."
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C "/tmp"
mv "/tmp/linux-amd64/helm" "${OUTPUT_DIR}/bin/helm"
chmod +x "${OUTPUT_DIR}/bin/helm"
rm -rf "/tmp/linux-amd64"

echo "--> [5/5] Packaging offline installer and manifests..."
cp "${PROJECT_ROOT}/install-airgap.sh" "${OUTPUT_DIR}/install-airgap.sh"
chmod +x "${OUTPUT_DIR}/install-airgap.sh"
cp -r "${PROJECT_ROOT}/manifests"/* "${OUTPUT_DIR}/manifests/"

cat << 'EOF' > "${OUTPUT_DIR}/README.md"
# k3s Offline Air-Gap Installation Package for RHEL 9.6

This package contains all binaries, RPMs, container images, and Kubernetes manifests required to deploy the complete platform without internet access.

## Quick Install on Air-Gapped RHEL 9.6:

```bash
tar -xzf k3s-airgap-rhel9-bundle.tar.gz
cd k3s-airgap-rhel9-bundle
sudo ./install-airgap.sh
```

## Included Components:
- `bin/k3s`: Standalone k3s server/agent binary
- `bin/helm`: Standalone Helm 3 binary
- `rpms/k3s-selinux*.rpm`: Pre-downloaded SELinux policy RPM for RHEL 9
- `images/`: Pre-staged core container images
- `k3s-install.sh`: Offline-compatible k3s bootstrap script
- `manifests/`: Declarative manifests for Forgejo, Runner, Plane, and It's a Plan
EOF

echo "Creating compressed tarball: ${ARCHIVE_FILE}..."
tar -czf "${ARCHIVE_FILE}" -C "${PROJECT_ROOT}" "${BUNDLE_NAME}"

echo "=============================================================================="
echo " Air-Gap Bundle successfully created!"
echo " Location: ${ARCHIVE_FILE}"
echo " File Size: $(du -h "${ARCHIVE_FILE}" | awk '{print $1}')"
echo ""
echo " To install on your air-gapped RHEL 9.6 server:"
echo "   1. Transfer ${ARCHIVE_FILE} to the server (via scp/USB)"
echo "   2. tar -xzf ${BUNDLE_NAME}.tar.gz"
echo "   3. cd ${BUNDLE_NAME} && sudo ./install-airgap.sh"
echo "=============================================================================="
