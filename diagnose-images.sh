#!/usr/bin/env bash
# ==============================================================================
# Image Pull Diagnostic & Registry Verification Tool
# Diagnoses why pods are failing with ImagePullBackOff / ErrImagePull.
#
# Usage:
#   sudo ./diagnose-images.sh
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${BLUE}${BOLD}==============================================================================${NC}"
echo -e "${BLUE}${BOLD}            🔍 Container Image Pull Diagnostic Tool${NC}"
echo -e "${BLUE}${BOLD}==============================================================================${NC}\n"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
if [ ! -f "${KUBECONFIG}" ] && [ -f /root/.kube/config ]; then
    export KUBECONFIG=/root/.kube/config
fi

# 1. Check Pods in ErrImagePull / ImagePullBackOff
echo -e "${CYAN}${BOLD}[1/4] Inspecting Pods with Pull Errors across all Namespaces...${NC}"
FAILED_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E "(ImagePullBackOff|ErrImagePull)" || true)

if [ -z "${FAILED_PODS}" ]; then
    echo -e "${GREEN}✔ No pods currently in ImagePullBackOff or ErrImagePull state!${NC}"
else
    echo -e "${RED}✖ Found pods with image pull failures:${NC}"
    echo "${FAILED_PODS}"
    echo ""
    echo -e "${CYAN}${BOLD}[2/4] Detailed Failure Reasons from Kubernetes Events:${NC}"
    kubectl get events -A --field-selector reason=Failed -o custom-columns=NAMESPACE:.metadata.namespace,POD:.involvedObject.name,REASON:.reason,MESSAGE:.message --sort-by=.lastTimestamp | grep -E "(pull|image|Image)" | tail -n 20 || true
fi

# 3. Direct Pull Test from Registries
echo -e "\n${CYAN}${BOLD}[3/4] Testing Direct Registry Connectivity via containerd (crictl)...${NC}"
TEST_IMAGES=(
    "docker.io/library/alpine:latest"
    "quay.io/jetstack/cert-manager-controller:v1.17.1"
    "code.forgejo.org/forgejo/runner:4.0.1"
    "ghcr.io/croffasia/itsaplan-api:latest"
)

for img in "${TEST_IMAGES[@]}"; do
    echo -n " - Testing pull for ${img}... "
    PULL_OUT=$(crictl pull "${img}" 2>&1 || true)
    if echo "${PULL_OUT}" | grep -q -E "(Image is up to date|Pulled)"; then
        echo -e "${GREEN}SUCCESS${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo "   -> Error: ${PULL_OUT}"
    fi
done

# 4. Check Local Image Cache
echo -e "\n${CYAN}${BOLD}[4/4] Checking Local Container Images in containerd...${NC}"
TOTAL_LOADED=$(crictl images -q 2>/dev/null | wc -l || echo "0")
echo " - Total images cached locally: ${TOTAL_LOADED}"
if [ -d /var/lib/rancher/k3s/agent/images ]; then
    echo " - Airgap bundle directory (/var/lib/rancher/k3s/agent/images):"
    ls -lh /var/lib/rancher/k3s/agent/images/ 2>/dev/null || true
fi

echo -e "\n${BLUE}${BOLD}==============================================================================${NC}"
echo -e "${BLUE}${BOLD}                        Diagnostic Complete${NC}"
echo -e "${BLUE}${BOLD}==============================================================================${NC}\n"
