#!/usr/bin/env bash
# ==============================================================================
# Workload Uninstaller & Cleanup Engine for k3s
# Cleanly removes deployed workloads, persistent data volumes, and namespaces:
#   1. Forgejo Git Forge
#   2. Forgejo DinD Runner
#   3. Plane Community Edition (plane.so)
#   4. It's a Plan (itsaplan.dev)
#   5. cert-manager & ClusterIssuers (optional / with --include-cert-manager)
#
# Features:
#   - Interactive confirmation prompt with automatic --yes / -y bypass
#   - Complete data purge (wipes PVCs so future deploys start with fresh DBs)
#   - Selective uninstall flags (--plane, --forgejo, --itsaplan, --all)
#   - Piped curl-safe (curl ... | sudo bash -s -- --all -y)
#   - Zero external dependencies (uses standard kubectl + coreutils/python)
#
# Usage:
#   sudo ./uninstall-workloads.sh                     # Removes 4 apps, preserves cert-manager
#   sudo ./uninstall-workloads.sh --all -y           # Removes ALL 5 workloads including cert-manager
#   sudo ./uninstall-workloads.sh --plane -y         # Removes ONLY Plane CE & its database
#   sudo ./uninstall-workloads.sh --forgejo -y       # Removes ONLY Forgejo & Runner
#   sudo ./uninstall-workloads.sh --itsaplan -y      # Removes ONLY It's a Plan
#   sudo ./uninstall-workloads.sh --keep-data -y     # Deletes workloads but preserves PVCs
# ==============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "${PWD}")"

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

# Defaults
PURGE_DATA=true
ASSUME_YES=false
UNINSTALL_FORGEJO=false
UNINSTALL_RUNNER=false
UNINSTALL_PLANE=false
UNINSTALL_ITSAPLAN=false
UNINSTALL_VAULTWARDEN=false
UNINSTALL_CERT_MANAGER=false
SPECIFIC_TARGET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--force|-f)
            ASSUME_YES=true; shift ;;
        --all)
            UNINSTALL_FORGEJO=true
            UNINSTALL_RUNNER=true
            UNINSTALL_PLANE=true
            UNINSTALL_ITSAPLAN=true
            UNINSTALL_VAULTWARDEN=true
            UNINSTALL_CERT_MANAGER=true
            SPECIFIC_TARGET=true
            shift ;;
        --plane)
            UNINSTALL_PLANE=true
            SPECIFIC_TARGET=true
            shift ;;
        --forgejo)
            UNINSTALL_FORGEJO=true
            UNINSTALL_RUNNER=true
            SPECIFIC_TARGET=true
            shift ;;
        --runner)
            UNINSTALL_RUNNER=true
            SPECIFIC_TARGET=true
            shift ;;
        --itsaplan)
            UNINSTALL_ITSAPLAN=true
            SPECIFIC_TARGET=true
            shift ;;
        --vaultwarden)
            UNINSTALL_VAULTWARDEN=true
            SPECIFIC_TARGET=true
            shift ;;
        --cert-manager)
            UNINSTALL_CERT_MANAGER=true
            SPECIFIC_TARGET=true
            shift ;;
        --include-cert-manager)
            UNINSTALL_CERT_MANAGER=true; shift ;;
        --keep-data)
            PURGE_DATA=false; shift ;;
        -h|--help)
            cat << 'EOF'
Usage: ./uninstall-workloads.sh [OPTIONS]

Options:
  --all                  Uninstall ALL workloads including cert-manager
  --plane                Uninstall Plane CE only (backend, frontend, postgres, minio)
  --forgejo              Uninstall Forgejo Git Forge and DinD Runner
  --itsaplan             Uninstall It's a Plan only
  --cert-manager         Uninstall cert-manager & ClusterIssuers only
  --include-cert-manager Include cert-manager in the default uninstall
  --keep-data            Delete workloads but keep PersistentVolumeClaims (PVCs)
  -y, --yes, --force     Skip confirmation prompt and proceed non-interactively
  -h, --help             Show this help message and exit

Examples:
  sudo ./uninstall-workloads.sh -y
  sudo ./uninstall-workloads.sh --plane -y
  sudo ./uninstall-workloads.sh --all -y
EOF
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"; shift ;;
    esac
done

# If no specific component was requested, default to all user workloads (preserving cert-manager)
if [ "$SPECIFIC_TARGET" = false ]; then
    UNINSTALL_FORGEJO=true
    UNINSTALL_RUNNER=true
    UNINSTALL_PLANE=true
    UNINSTALL_ITSAPLAN=true
    UNINSTALL_VAULTWARDEN=true
fi

echo -e "${RED}${BOLD}"
cat << 'EOF'
  _   _       _           _        _ _  __        __            _     _                 _     
 | | | |_ __ (_)_ __  ___| |_ __ _| | | \ \      / /___  _ __  | | __| | ___   __ _  __| |___ 
 | | | | '_ \| | '_ \/ __| __/ _` | | |  \ \ /\ / // _ \| '__| | |/ _` |/ _ \ / _` |/ _` / __|
 | |_| | | | | | | | \__ \ || (_| | | |   \ V  V /| (_) | |    | | (_| | (_) | (_| | (_| \__ \
  \___/|_| |_|_|_| |_|___/\__\__,_|_|_|    \_/\_/  \___/|_|    |_|\__,_|\___/ \__,_|\__,_|___/
EOF
echo -e " Workload Purge & Environment Cleaner for k3s${NC}\n"

# ------------------------------------------------------------------------------
# Locate kubectl & kubeconfig
# ------------------------------------------------------------------------------
if [ -f /etc/rancher/k3s/k3s.yaml ] && [ -z "${KUBECONFIG:-}" ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /root/.kube/config ] && [ -z "${KUBECONFIG:-}" ]; then
    export KUBECONFIG=/root/.kube/config
fi

if ! command -v kubectl >/dev/null 2>&1; then
    for kbin in /usr/local/bin/kubectl /usr/bin/kubectl /usr/local/bin/k3s /usr/bin/k3s; do
        if [ -x "$kbin" ]; then
            if [[ "$kbin" == *k3s ]]; then
                kubectl() { "$kbin" kubectl "$@"; }
                export -f kubectl 2>/dev/null || true
            else
                export PATH="$(dirname "$kbin"):$PATH"
            fi
            break
        fi
    done
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    log_error "Cannot connect to Kubernetes API server! Check: sudo systemctl status k3s"
    exit 1
fi

# ------------------------------------------------------------------------------
# Summary & User Confirmation
# ------------------------------------------------------------------------------
echo -e "${BOLD}Target Components to Uninstall:${NC}"
[ "$UNINSTALL_PLANE" = true ] && echo -e "  - ${CYAN}Plane Community Edition${NC} (namespace: plane)"
[ "$UNINSTALL_FORGEJO" = true ] && echo -e "  - ${CYAN}Forgejo Git Forge${NC} (namespace: forgejo)"
[ "$UNINSTALL_RUNNER" = true ] && echo -e "  - ${CYAN}Forgejo Actions DinD Runner${NC} (namespace: forgejo-runner)"
[ "$UNINSTALL_ITSAPLAN" = true ] && echo -e "  - ${CYAN}It's a Plan Issue Tracker${NC} (namespace: itsaplan)"
[ "$UNINSTALL_VAULTWARDEN" = true ] && echo -e "  - ${CYAN}Vaultwarden Secrets Manager${NC} (namespace: vaultwarden)"
[ "$UNINSTALL_CERT_MANAGER" = true ] && echo -e "  - ${CYAN}cert-manager & TLS ClusterIssuers${NC} (namespace: cert-manager)"

if [ "$PURGE_DATA" = true ]; then
    echo -e "  - ${RED}${BOLD}ALL PersistentVolumeClaims (PVCs) & databases WILL BE PURGED!${NC}"
else
    echo -e "  - ${YELLOW}PersistentVolumeClaims (PVCs) will be PRESERVED.${NC}"
fi
echo ""

if [ "$ASSUME_YES" = false ]; then
    echo -en "${YELLOW}${BOLD}Are you sure you want to proceed with uninstallation? [y/N]: ${NC}"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            log_info "Operation cancelled by user."
            exit 0
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# Helper: Clean Namespace
# ------------------------------------------------------------------------------
clean_namespace() {
    local ns="$1"
    local desc="$2"

    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        log_info "Namespace '${ns}' does not exist. Skipping."
        return 0
    fi

    log_step "Uninstalling ${desc} (namespace: ${ns})..."

    # 1. Delete Helm releases if any were tracked
    if command -v helm >/dev/null 2>&1; then
        for rel in $(helm list -n "$ns" -q 2>/dev/null || true); do
            log_info "Removing Helm release: ${rel}..."
            helm uninstall "$rel" -n "$ns" >/dev/null 2>&1 || true
        done
    fi

    # 2. Delete Workload Resources
    log_info "Deleting deployments, statefulsets, daemonsets, and jobs in '${ns}'..."
    kubectl delete deployment,statefulset,daemonset,job --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true

    # 3. Delete Ingress & Services
    log_info "Deleting services, ingresses, and ingressroutes in '${ns}'..."
    kubectl delete ingress,ingressroute,middleware,service --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true

    # 4. Delete Pods immediately
    log_info "Terminating active pods in '${ns}'..."
    kubectl delete pod --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true

    # 5. Handle Persistent Data
    if [ "$PURGE_DATA" = true ]; then
        log_info "Purging PersistentVolumeClaims in '${ns}'..."
        # Strip finalizers if any PVC is stuck
        for pvc in $(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' || true); do
            kubectl patch pvc "$pvc" -n "$ns" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        done
        kubectl delete pvc --all -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
    fi

    # 6. Delete Secrets & ConfigMaps
    kubectl delete secret,configmap --all -n "$ns" >/dev/null 2>&1 || true

    # 7. Delete the Namespace itself
    log_info "Removing namespace '${ns}'..."
    kubectl delete namespace "$ns" --timeout=30s >/dev/null 2>&1 || {
        log_warn "Namespace '${ns}' taking long to terminate. Stripping any remaining finalizers..."
        # Strip finalizers using Python if namespace is stuck in Terminating
        python3 -c "
import urllib.request, json, ssl, subprocess
try:
    raw = subprocess.check_output(['kubectl', 'get', 'namespace', '${ns}', '-o', 'json'])
    doc = json.loads(raw)
    doc['spec']['finalizers'] = []
    p = subprocess.Popen(['kubectl', 'replace', '--raw', '/api/v1/namespaces/${ns}/finalize', '-f', '-'], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p.communicate(input=json.dumps(doc).encode())
except Exception:
    pass
" 2>/dev/null || true
    }
    log_success "Cleaned '${ns}' successfully."
}

# ------------------------------------------------------------------------------
# 1. Uninstall It's a Plan
# ------------------------------------------------------------------------------
if [ "$UNINSTALL_ITSAPLAN" = true ]; then
    clean_namespace "itsaplan" "It's a Plan AI Issue Tracker"
fi

# ------------------------------------------------------------------------------
# 2. Uninstall Plane Community Edition
# ------------------------------------------------------------------------------
if [ "$UNINSTALL_PLANE" = true ]; then
    clean_namespace "plane" "Plane Community Edition"
fi

# ------------------------------------------------------------------------------
# 3. Uninstall Forgejo Actions DinD Runner
# ------------------------------------------------------------------------------
if [ "$UNINSTALL_RUNNER" = true ]; then
    clean_namespace "forgejo-runner" "Forgejo Actions Runner"
fi

# ------------------------------------------------------------------------------
# 4. Uninstall Forgejo Git Forge
# ------------------------------------------------------------------------------
if [ "$UNINSTALL_FORGEJO" = true ]; then
    clean_namespace "forgejo" "Forgejo Git Server"
fi

# ------------------------------------------------------------------------------
# 5. Uninstall Vaultwarden
# ------------------------------------------------------------------------------
if [ "$UNINSTALL_VAULTWARDEN" = true ]; then
    clean_namespace "vaultwarden" "Vaultwarden Team Secrets Manager"
fi

# ------------------------------------------------------------------------------
# 6. Uninstall cert-manager & ClusterIssuers (if requested)
# ------------------------------------------------------------------------------
if [ "$UNINSTALL_CERT_MANAGER" = true ]; then
    log_step "Uninstalling cert-manager & TLS ClusterIssuers..."
    kubectl delete clusterissuer letsencrypt-prod letsencrypt-staging selfsigned-issuer --ignore-not-found=true >/dev/null 2>&1 || true
    clean_namespace "cert-manager" "cert-manager Core Services"
    log_info "Deleting cert-manager CustomResourceDefinitions (CRDs)..."
    kubectl delete crd \
        certificaterequests.cert-manager.io \
        certificates.cert-manager.io \
        challenges.acme.cert-manager.io \
        clusterissuers.cert-manager.io \
        issuers.cert-manager.io \
        orders.acme.cert-manager.io \
        --ignore-not-found=true >/dev/null 2>&1 || true
    log_success "cert-manager resources and CRDs removed."
fi

# ------------------------------------------------------------------------------
# Final Verification
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}           🎉 UNINSTALLATION & CLEANUP COMPLETED! 🎉${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"

echo -e "${BOLD}Current Active Namespaces in Cluster:${NC}"
kubectl get namespaces || true
echo ""

echo "To redeploy the stack freshly from scratch, run:"
echo "  curl --tlsv1.2 --tls-max 1.2 -fsSL https://gist.githubusercontent.com/net-pilgrim/29dfd0b6dfb41c8c3f32384c3a723e67/raw/deploy-workloads.sh | sudo bash"
echo ""
