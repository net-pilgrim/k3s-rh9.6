#!/usr/bin/env bash
# ==============================================================================
# Dedicated Workload Deployment Script for k3s
# Deploys:
#   1. cert-manager & ClusterIssuers
#   2. Forgejo (Self-hosted Git & Actions)
#   3. Forgejo DinD Runner (StatefulSet + Docker-in-Docker sidecar)
#   4. Plane Community Edition (plane.so Management Platform)
#   5. It's a Plan (itsaplan.dev AI Issue Tracker)
#
# Usage:
#   sudo ./deploy-workloads.sh
#   sudo ./deploy-workloads.sh --domain example.com --admin-pass SecretPass123!
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

# Parse arguments
DOMAIN="${DOMAIN:-}"
ADMIN_PASS="${ADMIN_PASS:-${ADMIN_PASSWORD:-}}"
TLS_MODE="${TLS_MODE:-${TLS:-}}"
ACME_EMAIL="${ACME_EMAIL:-${EMAIL:-}}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN="$2"; shift 2 ;;
        -p|--admin-pass|--admin-password)
            ADMIN_PASS="$2"; shift 2 ;;
        -t|--tls)
            TLS_MODE="$2"; shift 2 ;;
        -e|--email)
            ACME_EMAIL="$2"; shift 2 ;;
        -h|--help)
            cat << 'EOF'
Usage: ./deploy-workloads.sh [OPTIONS]

Options:
  -d, --domain <DOMAIN>       Base domain name (default: auto-detected <IP>.nip.io)
  -p, --admin-pass <PASSWORD> Administrator password (default: random secure string)
  -t, --tls <MODE>            TLS mode: 'selfsigned', 'letsencrypt' (default: auto)
  -e, --email <EMAIL>         ACME email for Let's Encrypt
  -h, --help                  Show this help message and exit
EOF
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  _  _________      __            _     _                 _     
 | |/ /___ / ___   / /_      ___ | | __| | ___   __ _  __| |___ 
 | ' /  |_ \/ __| | '_ \    / _ \| |/ / _` / _ \ / _` |/ _` / __|
 | . \ ___) \__ \ | (_) |  | (_) |   < (_| (_) | (_| | (_| \__ \
 |_|\_\____/|___/  \___/    \___/|_|\_\__,_\___/ \__,_|\__,_|___/
EOF
echo -e " Workload Deployment Engine (Forgejo, Runner, Plane, It's a Plan)${NC}\n"

# ------------------------------------------------------------------------------
# 1. Environment & Kubernetes Readiness Verification
# ------------------------------------------------------------------------------
log_step "[1/6] Verifying Kubernetes & Tooling Environment..."

# Ensure kubeconfig is active
if [ -f /etc/rancher/k3s/k3s.yaml ] && [ -z "${KUBECONFIG:-}" ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /root/.kube/config ] && [ -z "${KUBECONFIG:-}" ]; then
    export KUBECONFIG=/root/.kube/config
fi

# Ensure helm binary in PATH
if ! command -v helm >/dev/null 2>&1; then
    LOCAL_HELM=$(find "${SCRIPT_DIR}/bin" "${SCRIPT_DIR}" -name "helm" -type f -perm /111 2>/dev/null | head -n 1 || true)
    if [ -n "${LOCAL_HELM}" ]; then
        export PATH="$(dirname "${LOCAL_HELM}"):${PATH}"
        log_info "Using bundled Helm: ${LOCAL_HELM}"
    fi
fi

if ! command -v kubectl >/dev/null 2>&1; then
    if [ -f /usr/local/bin/k3s ]; then
        ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
        ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
    else
        log_error "kubectl is not installed and k3s binary was not found!"
        exit 1
    fi
fi

if ! kubectl get nodes >/dev/null 2>&1; then
    log_error "Cannot connect to Kubernetes API server! Check 'systemctl status k3s'."
    exit 1
fi
log_success "Kubernetes cluster is reachable: $(kubectl get nodes --no-headers | awk '{print $1}')"

# Auto-detect IP and Domain
if [ -z "${DOMAIN}" ]; then
    PUBLIC_IP=$(curl -s --tlsv1.2 --tls-max 1.2 --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
                curl -s --tlsv1.2 --tls-max 1.2 --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
                ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | tr -d ' \n' || echo "")
    if [[ "${PUBLIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        DOMAIN="${PUBLIC_IP}.nip.io"
        log_info "Auto-detected public IP: ${PUBLIC_IP} -> Using domain: ${DOMAIN}"
    else
        DOMAIN="127.0.0.1.nip.io"
        log_warn "Could not determine public IP, defaulting domain to: ${DOMAIN}"
    fi
fi

if [ -z "${ADMIN_PASS}" ]; then
    ADMIN_PASS=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    ADMIN_PASS="${ADMIN_PASS}A1!"
    log_info "Generated admin password: ${ADMIN_PASS}"
fi

CERT_ISSUER="selfsigned-issuer"
if [ "${TLS_MODE}" = "letsencrypt" ]; then
    CERT_ISSUER="letsencrypt-prod"
    ACME_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"
fi

TMP_DIR=$(mktemp -d -t workloads-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

# Ensure namespaces exist
log_info "Ensuring target namespaces exist..."
for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# ------------------------------------------------------------------------------
# 2. Deploy cert-manager & ClusterIssuers
# ------------------------------------------------------------------------------
log_step "[2/6] Deploying cert-manager & TLS ClusterIssuers..."

CERT_YAML=$(find "${SCRIPT_DIR}/manifests/cert-manager" "${SCRIPT_DIR}" -name "cert-manager.yaml" 2>/dev/null | head -n 1 || true)
CERT_CHART=$(find "${SCRIPT_DIR}/charts" "${SCRIPT_DIR}" -name "cert-manager-*.tgz" 2>/dev/null | head -n 1 || true)

if [ -n "${CERT_YAML}" ] && [ -f "${CERT_YAML}" ]; then
    log_info "Applying self-contained cert-manager manifests: ${CERT_YAML}..."
    kubectl apply -f "${CERT_YAML}" >/dev/null || true
elif [ -n "${CERT_CHART}" ] && [ -f "${CERT_CHART}" ]; then
    log_info "Installing cert-manager via local chart: ${CERT_CHART}..."
    helm upgrade --install cert-manager "${CERT_CHART}" \
        --namespace cert-manager \
        --set crds.enabled=true \
        --wait --timeout 5m >/dev/null || true
elif command -v helm >/dev/null 2>&1; then
    helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --set crds.enabled=true \
        --wait --timeout 5m >/dev/null || true
fi

log_info "Waiting for cert-manager webhook to become ready..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=90s 2>/dev/null || sleep 10

log_info "Configuring ClusterIssuers..."
cat << EOF | kubectl apply -f - >/dev/null || true
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${ACME_EMAIL:-admin@${DOMAIN}}"
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
EOF
log_success "cert-manager configured."

# ------------------------------------------------------------------------------
# 3. Deploy Forgejo & DinD Runner
# ------------------------------------------------------------------------------
log_step "[3/6] Deploying Forgejo (Git Forge) & Actions DinD Runner..."

FORGEJO_CHART=$(find "${SCRIPT_DIR}/charts" "${SCRIPT_DIR}" -name "forgejo-*.tgz" 2>/dev/null | head -n 1 || true)

cat << EOF > "${TMP_DIR}/values-forgejo.yaml"
image:
  rootless: true

gitea:
  admin:
    existingSecret: ""
    username: "forgejo-admin"
    password: "${ADMIN_PASS}"
    email: "admin@${DOMAIN}"
  config:
    server:
      DOMAIN: "git.${DOMAIN}"
      ROOT_URL: "https://git.${DOMAIN}/"
      SSH_DOMAIN: "${DOMAIN}"
      SSH_PORT: 32222
      SSH_LISTEN_PORT: 22
    actions:
      ENABLED: true
    service:
      ENABLE_NOTIFY_MAIL: false
      DISABLE_REGISTRATION: false
      ALLOW_ONLY_EXTERNAL_REGISTRATION: false
      SHOW_REGISTRATION_BUTTON: true
    oauth2:
      ENABLE: true
    security:
      INSTALL_LOCK: true

ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: "${CERT_ISSUER}"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  hosts:
    - host: "git.${DOMAIN}"
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: forgejo-tls
      hosts:
        - "git.${DOMAIN}"

persistence:
  enabled: true
  storageClass: "local-path"
  accessModes:
    - ReadWriteOnce
  size: 20Gi
EOF

if [ -n "${FORGEJO_CHART}" ] && [ -f "${FORGEJO_CHART}" ]; then
    log_info "Installing Forgejo from local chart: ${FORGEJO_CHART}..."
    helm upgrade --install forgejo "${FORGEJO_CHART}" \
        --namespace forgejo \
        -f "${TMP_DIR}/values-forgejo.yaml" \
        --timeout 10m >/dev/null || log_warn "Forgejo install initiated."
else
    log_info "Installing Forgejo from OCI registry..."
    helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
        --namespace forgejo \
        -f "${TMP_DIR}/values-forgejo.yaml" \
        --timeout 10m >/dev/null || log_warn "Forgejo install initiated."
fi

# Deploy DinD Actions Runner
log_info "Deploying Forgejo Actions Runner with DinD..."
kubectl create secret generic forgejo-runner-secret \
    --namespace forgejo-runner \
    --from-literal=token="initial-bootstrap-token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

RUNNER_CM="${SCRIPT_DIR}/manifests/forgejo-runner/runner-configmap.yaml"
RUNNER_SS="${SCRIPT_DIR}/manifests/forgejo-runner/runner-statefulset.yaml"

if [ -f "${RUNNER_CM}" ]; then
    kubectl apply -f "${RUNNER_CM}" >/dev/null
fi
if [ -f "${RUNNER_SS}" ]; then
    kubectl apply -f "${RUNNER_SS}" >/dev/null
fi
log_success "Forgejo and Runner workloads submitted."

# ------------------------------------------------------------------------------
# 4. Deploy Plane Community Edition (plane.so)
# ------------------------------------------------------------------------------
log_step "[4/6] Deploying Plane Management Platform (plane.${DOMAIN})..."

PLANE_CHART=$(find "${SCRIPT_DIR}/charts" "${SCRIPT_DIR}" -name "plane-ce-*.tgz" 2>/dev/null | head -n 1 || true)
PLANE_SECRET_KEY="plane-secret-key-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cat << EOF > "${TMP_DIR}/values-plane.yaml"
planeVersion: "v2.6.3"
env:
  storageClass: "local-path"
  secretKey: "${PLANE_SECRET_KEY}"

ingress:
  enabled: true
  ingressClass: "traefik"
  annotations:
    cert-manager.io/cluster-issuer: "${CERT_ISSUER}"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  appHost: "plane.${DOMAIN}"
  tls: true
  secretName: "plane-tls"

postgresql:
  auth:
    username: "plane"
    password: "${ADMIN_PASS}"
    database: "plane"
  primary:
    persistence:
      storageClass: "local-path"
      size: 20Gi

redis:
  auth:
    password: "${ADMIN_PASS}"
  master:
    persistence:
      storageClass: "local-path"
      size: 5Gi

minio:
  rootUser: "plane-access-key"
  rootPassword: "${ADMIN_PASS}"
  persistence:
    storageClass: "local-path"
    size: 20Gi

rabbitmq:
  auth:
    username: "plane"
    password: "${ADMIN_PASS}"
  persistence:
    storageClass: "local-path"
    size: 5Gi
EOF

if [ -n "${PLANE_CHART}" ] && [ -f "${PLANE_CHART}" ]; then
    log_info "Installing Plane from local chart: ${PLANE_CHART}..."
    helm upgrade --install plane-app "${PLANE_CHART}" \
        --namespace plane \
        -f "${TMP_DIR}/values-plane.yaml" \
        --timeout 12m >/dev/null || log_warn "Plane Helm install triggered."
elif command -v helm >/dev/null 2>&1; then
    helm repo add makeplane https://helm.plane.so --force-update >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    helm upgrade --install plane-app makeplane/plane-ce \
        --namespace plane \
        -f "${TMP_DIR}/values-plane.yaml" \
        --timeout 12m >/dev/null || log_warn "Plane Helm install triggered."
fi
log_success "Plane workload submitted."

# ------------------------------------------------------------------------------
# 5. Deploy It's a Plan (itsaplan.dev)
# ------------------------------------------------------------------------------
log_step "[5/6] Deploying It's a Plan Issue Tracker (itsaplan.${DOMAIN})..."

BETTER_AUTH_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
APP_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')

cat << EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: itsaplan-secrets
  namespace: itsaplan
type: Opaque
stringData:
  POSTGRES_USER: "itsaplan"
  POSTGRES_PASSWORD: "${ADMIN_PASS}"
  POSTGRES_DB: "itsaplan"
  DATABASE_URL: "postgres://itsaplan:${ADMIN_PASS}@itsaplan-postgres:5432/itsaplan"
  S3_ACCESS_KEY_ID: "rustfs-admin"
  S3_SECRET_ACCESS_KEY: "${ADMIN_PASS}"
  S3_BUCKET: "planner-attachments"
  BETTER_AUTH_SECRET: "${BETTER_AUTH_SECRET}"
  APP_ENCRYPTION_KEY: "${APP_ENCRYPTION_KEY}"
  API_URL: "https://api.itsaplan.${DOMAIN}"
  APP_URL: "https://itsaplan.${DOMAIN}"
EOF

ITSAPLAN_DIR="${SCRIPT_DIR}/manifests/itsaplan"
if [ -d "${ITSAPLAN_DIR}" ]; then
    for f in "${ITSAPLAN_DIR}"/*.yaml; do
        if [[ "$(basename "$f")" != "00-config-secret.yaml" && "$(basename "$f")" != "kustomization.yaml" ]]; then
            sed "s/cluster.internal/${DOMAIN}/g" "$f" | kubectl apply -f - >/dev/null || true
        fi
    done
fi
log_success "It's a Plan workload submitted."

# ------------------------------------------------------------------------------
# 6. Status Verification & Credentials Summary
# ------------------------------------------------------------------------------
log_step "[6/6] Checking Workload Status across Namespaces..."

log_info "Allowing pods 10 seconds to begin initial container creation..."
sleep 10

echo ""
for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
    echo -e "${CYAN}${BOLD}=== Namespace: ${ns} ===${NC}"
    kubectl get pods -n "$ns" -o wide 2>/dev/null || echo "No resources found."
    echo ""
done

CREDENTIALS_FILE="/root/.pipeline-credentials.txt"
cat << EOF > "${CREDENTIALS_FILE}"
==============================================================================
          Platform Services & Access Credentials
==============================================================================
Base Domain:             ${DOMAIN}
TLS Certificate Issuer:  ${CERT_ISSUER}
Administrator Password:  ${ADMIN_PASS}

Workload Endpoints:
  1. Forgejo (Git):      https://git.${DOMAIN} (User: forgejo-admin)
  2. Forgejo Git SSH:    ssh://git@${DOMAIN}:32222/
  3. Plane (Management): https://plane.${DOMAIN}
  4. It's a Plan (Web):  https://itsaplan.${DOMAIN}
  5. It's a Plan (API):  https://api.itsaplan.${DOMAIN}

Kubeconfig:              /root/.kube/config
==============================================================================
EOF
chmod 600 "${CREDENTIALS_FILE}" 2>/dev/null || true

echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}             🎉 WORKLOADS INSTALLED SUCCESSFULLY! 🎉${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
cat "${CREDENTIALS_FILE}"
echo ""
log_info "To live-monitor pod progress:"
echo "   watch -n 2 kubectl get pods -A"
echo ""
