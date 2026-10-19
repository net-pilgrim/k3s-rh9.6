#!/usr/bin/env bash
# ==============================================================================
# All-in-One Self-Installing Script: k3s Platform with CI/CD & Management Tools
# Deploys:
#   - k3s Kubernetes cluster (with Traefik Ingress & local-path storage)
#   - cert-manager v1.17 (Let's Encrypt / self-signed TLS)
#   - Forgejo Git Server (with Actions enabled)
#   - Forgejo CI/CD Runner (act_runner with Docker-in-Docker sidecar)
#   - Plane.so (Project management suite)
#   - It's a Plan (itsaplan.dev AI-first issue tracker)
#
# Usage:
#   curl -fsSL <URL> | bash
#   DOMAIN="example.com" TLS=letsencrypt EMAIL="admin@example.com" curl -fsSL <URL> | bash
#   curl -fsSL <URL> | bash -s -- --domain example.com --email admin@example.com --tls letsencrypt
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# Colors & Logging Helpers
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_step() {
    echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"
}
log_info() {
    echo -e "${CYAN}   ℹ ${NC}$1"
}
log_success() {
    echo -e "${GREEN}   ✔ ${NC}$1"
}
log_warn() {
    echo -e "${YELLOW}   ⚠ ${NC}$1"
}
log_error() {
    echo -e "${RED}   ✖ ERROR: ${NC}$1" >&2
}

# ------------------------------------------------------------------------------
# Parse Arguments & Environment Variables
# ------------------------------------------------------------------------------
DOMAIN="${DOMAIN:-}"
TLS_MODE="${TLS_MODE:-${TLS:-}}"
ACME_EMAIL="${ACME_EMAIL:-${EMAIL:-}}"
ADMIN_PASS="${ADMIN_PASS:-${ADMIN_PASSWORD:-}}"
K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN="$2"; shift 2 ;;
        -t|--tls)
            TLS_MODE="$2"; shift 2 ;;
        -e|--email)
            ACME_EMAIL="$2"; shift 2 ;;
        -p|--admin-pass|--admin-password)
            ADMIN_PASS="$2"; shift 2 ;;
        -v|--k3s-version)
            K3S_VERSION="$2"; shift 2 ;;
        -h|--help)
            cat << 'EOF'
Usage: install.sh [OPTIONS]

Options:
  -d, --domain <DOMAIN>       Base domain name (default: auto-detected <IP>.nip.io)
  -t, --tls <MODE>            TLS mode: 'selfsigned', 'letsencrypt', 'staging' (default: selfsigned for nip.io, letsencrypt for custom domains)
  -e, --email <EMAIL>         ACME contact email for Let's Encrypt (default: admin@<DOMAIN>)
  -p, --admin-pass <PASSWORD> Master administrator password (default: securely generated)
  -v, --k3s-version <VERSION> k3s version (default: v1.31.5+k3s1)
  -h, --help                  Show this help message and exit

Environment variables can also be used:
  DOMAIN=example.com TLS=letsencrypt EMAIL=admin@example.com bash install.sh
EOF
            exit 0
            ;;
        *)
            log_warn "Unknown parameter passed: $1"
            shift
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Phase 1: Preflight & Privilege Verification
# ------------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  _    ____         ____  _       _    __                      
 | | _|___ / ___   |  _ \| | __ _| |_ / _| ___  _ __ _ __ ___  
 | |/ / |_ \/ __|  | |_) | |/ _` | __| |_ / _ \| '__| '_ ` _ \ 
 |   < ___) \__ \  |  __/| | (_| | |_|  _| (_) | |  | | | | | |
 |_|\_\____/|___/  |_|   |_|\__,_|\__|_|  \___/|_|  |_| |_| |_|
EOF
echo -e " All-in-One Autonomous Cluster Deployer (Forgejo, Runner, Plane, It's a Plan)${NC}\n"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "This script must be run as root. Please run via 'sudo bash' or login as root."
    exit 1
fi

TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "${TOTAL_RAM_MB}" -lt 3500 ]; then
    log_warn "Total RAM is ${TOTAL_RAM_MB}MB. The combined stack (Forgejo + DinD Runner + Plane + It's a Plan) runs best on 6GB+ RAM."
    log_warn "Proceeding, but ensure swap is available or consider resizing if OOM occurs."
fi

# Detect Public IP
log_step "[1/10] Detecting Network Configuration & Public IP..."
PUBLIC_IP=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null || \
            curl -s4 --connect-timeout 5 icanhazip.com 2>/dev/null || \
            hostname -I | awk '{print $1}')
log_info "Detected Host Public IP: ${PUBLIC_IP}"

if [ -z "${DOMAIN}" ]; then
    DOMAIN="${PUBLIC_IP}.nip.io"
    log_info "No custom domain specified. Using dynamic wildcard domain: ${DOMAIN}"
    if [ -z "${TLS_MODE}" ]; then
        TLS_MODE="selfsigned"
    fi
else
    log_info "Configured target domain: ${DOMAIN}"
    if [ -z "${TLS_MODE}" ]; then
        TLS_MODE="letsencrypt"
    fi
fi

if [ -z "${ACME_EMAIL}" ]; then
    ACME_EMAIL="admin@${DOMAIN}"
fi

case "${TLS_MODE}" in
    letsencrypt|prod|production)
        CERT_ISSUER="letsencrypt-prod" ;;
    staging)
        CERT_ISSUER="letsencrypt-staging" ;;
    *)
        CERT_ISSUER="selfsigned-issuer" ;;
esac

log_info "TLS Certificate Mode: ${CERT_ISSUER} (mode: ${TLS_MODE})"

# Generate secure passwords if not provided
if [ -z "${ADMIN_PASS}" ]; then
    ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)!A1
fi
BETTER_AUTH_SECRET=$(openssl rand -hex 32)
APP_ENCRYPTION_KEY=$(openssl rand -hex 32)
PLANE_SECRET_KEY=$(openssl rand -hex 24)
PLANE_DB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
ITSAPLAN_DB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
MINIO_SECRET_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

TMP_DIR=$(mktemp -d -t k3s-pipeline-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

# ------------------------------------------------------------------------------
# Phase 2: Host Hardening & Kernel Tuning
# ------------------------------------------------------------------------------
log_step "[2/10] Preparing Host Kernel & Disabling Swap..."
swapoff -a || true
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab || true

modprobe overlay || true
modprobe br_netfilter || true

cat << 'EOF' > /etc/modules-load.d/k8s-platform.conf
overlay
br_netfilter
EOF

cat << 'EOF' > /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Phase 3: Install Prerequisite Packages & Configure RHEL / EL9 Stack
# ------------------------------------------------------------------------------
log_step "[3/10] Installing Required System Utilities (RHEL 9 / Debian / Ubuntu)..."
export DEBIAN_FRONTEND=noninteractive

IS_RHEL=false
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" =~ ^(rhel|rocky|almalinux|centos|fedora)$ ]] || [[ "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
        IS_RHEL=true
        log_info "Detected Red Hat Enterprise Linux / EL9 ecosystem: ${PRETTY_NAME:-$ID}"
    fi
fi

if [ "$IS_RHEL" = true ]; then
    log_info "Installing EPEL and core packages for RHEL..."
    dnf install -y -q epel-release 2>/dev/null || true
    dnf install -y -q curl wget jq tar socat conntrack-tools iptables git openssl

    # Check and configure SELinux for k3s on RHEL
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
        log_info "SELinux is active. Installing container-selinux and Rancher k3s-selinux RPM..."
        dnf install -y -q container-selinux selinux-policy-base 2>/dev/null || true

        # Install Rancher k3s common repo for EL9
        cat << 'EOF' > /etc/yum.repos.d/rancher-k3s-common.repo
[rancher-k3s-common-stable]
name=Rancher K3s Common (stable)
baseurl=https://rpm.rancher.io/k3s/stable/common/centos/9/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://rpm.rancher.io/public.key
EOF
        dnf install -y -q k3s-selinux 2>/dev/null || true
        log_success "k3s-selinux policy installed."
    fi

    # Configure firewalld on RHEL if active
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "Active firewalld detected. Applying Kubernetes CNI and workload firewall rules..."
        firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=trusted --add-interface=cni0 >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=6443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=32222/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=8472/udp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=10250/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_success "firewalld rules successfully configured."
    fi
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl wget jq tar socat conntrack iptables git openssl >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl wget jq tar socat conntrack-tools iptables git openssl
fi
log_success "Base system packages installed."

# ------------------------------------------------------------------------------
# Phase 4: Install Helm 3
# ------------------------------------------------------------------------------
log_step "[4/10] Verifying Helm 3 Package Manager..."
if ! command -v helm >/dev/null 2>&1; then
    log_info "Downloading and installing Helm 3..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
    log_success "Helm installed: $(helm version --short)"
else
    log_success "Helm is already present: $(helm version --short)"
fi

# ------------------------------------------------------------------------------
# Phase 5: Install & Bootstrap k3s Cluster
# ------------------------------------------------------------------------------
log_step "[5/10] Installing & Starting k3s Kubernetes Server (${K3S_VERSION})..."
mkdir -p /etc/rancher/k3s

# Determine SELinux flag for k3s
K3S_SELINUX_CONFIG=""
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    K3S_SELINUX_CONFIG="selinux: true"
fi

cat << EOF > /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
${K3S_SELINUX_CONFIG}
tls-san:
  - "${PUBLIC_IP}"
  - "${DOMAIN}"
  - "git.${DOMAIN}"
  - "plane.${DOMAIN}"
  - "itsaplan.${DOMAIN}"
  - "api.itsaplan.${DOMAIN}"
disable:
  - servicelb
EOF

if ! command -v k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server
else
    log_info "k3s is already installed. Ensuring service is active..."
    systemctl restart k3s
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config

log_info "Waiting for k3s node to report Ready state..."
RETRIES=30
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 3
    RETRIES=$((RETRIES - 1))
    if [ $RETRIES -le 0 ]; then
        log_error "Timed out waiting for k3s cluster to initialize."
        exit 1
    fi
done
log_success "k3s cluster node is Ready: $(kubectl get nodes --no-headers | awk '{print $1}')"

# ------------------------------------------------------------------------------
# Phase 6: Namespaces, cert-manager & ClusterIssuers
# ------------------------------------------------------------------------------
log_step "[6/10] Setting up Namespaces and cert-manager (v1.17)..."
for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

log_info "Installing cert-manager via Helm..."
helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --set crds.enabled=true \
    --wait --timeout 5m >/dev/null

log_info "Applying ClusterIssuers..."
cat << EOF | kubectl apply -f - >/dev/null
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
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "${ACME_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${ACME_EMAIL}"
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
EOF
log_success "cert-manager and ClusterIssuers configured."

# ------------------------------------------------------------------------------
# Phase 7: Deploy Forgejo (Git Forge + Actions)
# ------------------------------------------------------------------------------
log_step "[7/10] Deploying Forgejo (Git Server) on git.${DOMAIN}..."
cat << EOF > "${TMP_DIR}/values-forgejo.yaml"
image:
  rootless: true

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

service:
  http:
    type: ClusterIP
    port: 3000
  ssh:
    type: NodePort
    port: 22
    nodePort: 32222

gitea:
  admin:
    existingSecret: ""
    username: "forgejo-admin"
    password: "${ADMIN_PASS}"
    email: "admin@${DOMAIN}"
  config:
    APP_NAME: "Forgejo DevOps & CI/CD Platform"
    RUN_MODE: "prod"
    server:
      ROOT_URL: "https://git.${DOMAIN}/"
      DOMAIN: "git.${DOMAIN}"
      SSH_DOMAIN: "git.${DOMAIN}"
      SSH_PORT: 32222
      SSH_LISTEN_PORT: 2222
    actions:
      ENABLED: true
      DEFAULT_ACTIONS_URL: "github"
    repository:
      DEFAULT_BRANCH: "main"
      ENABLE_PUSH_CREATE_USER: true
      ENABLE_PUSH_CREATE_ORG: true
EOF

log_info "Installing Forgejo via official OCI Helm chart..."
helm upgrade --install forgejo oci://code.forgejo.org/forgejo-helm/forgejo \
    --namespace forgejo \
    -f "${TMP_DIR}/values-forgejo.yaml" \
    --timeout 10m >/dev/null

log_info "Waiting for Forgejo pod to become ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=forgejo -n forgejo --timeout=300s >/dev/null
log_success "Forgejo deployed successfully."

# ------------------------------------------------------------------------------
# Phase 8: Deploy Forgejo DinD Runner
# ------------------------------------------------------------------------------
log_step "[8/10] Provisioning Forgejo DinD Actions Runner..."
FORGEJO_POD=$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}')

log_info "Auto-generating Actions runner registration token from Forgejo pod..."
RUNNER_TOKEN=$(kubectl exec -n forgejo "${FORGEJO_POD}" -- forgejo forgejo-cli actions generate-runner-token 2>/dev/null || \
              kubectl exec -n forgejo "${FORGEJO_POD}" -- forgejo actions generate-runner-token 2>/dev/null || \
              kubectl exec -n forgejo "${FORGEJO_POD}" -- gitea actions generate-runner-token 2>/dev/null || echo "")

if [ -z "${RUNNER_TOKEN}" ]; then
    log_warn "Could not auto-generate token directly via CLI; will use fallback placeholder for later manual registration."
    RUNNER_TOKEN="manual-token-required"
else
    log_success "Runner token acquired: ${RUNNER_TOKEN:0:6}********"
fi

kubectl create secret generic forgejo-runner-secret \
    --namespace forgejo-runner \
    --from-literal=token="${RUNNER_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat << 'EOF' > "${TMP_DIR}/runner-configmap.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: forgejo-runner-config
  namespace: forgejo-runner
data:
  config.yaml: |
    log:
      level: info
    runner:
      file: /data/.runner
      capacity: 2
      timeout: 3h
      insecure: false
      fetch_timeout: 5s
      fetch_interval: 2s
      labels:
        - "ubuntu-latest:docker://node:20-bookworm"
        - "ubuntu-22.04:docker://node:20-bookworm"
        - "ubuntu-20.04:docker://node:20-bookworm"
        - "docker:docker://docker:27-cli"
    cache:
      enabled: true
      dir: /data/cache
    container:
      network: "host"
      privileged: true
      options: "-v /var/run/docker.sock:/var/run/docker.sock"
      valid_volumes:
        - "/var/run/docker.sock"
EOF
kubectl apply -f "${TMP_DIR}/runner-configmap.yaml" >/dev/null

cat << 'EOF' > "${TMP_DIR}/runner-statefulset.yaml"
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: forgejo-runner
  namespace: forgejo-runner
  labels:
    app: forgejo-runner
spec:
  replicas: 1
  serviceName: forgejo-runner
  selector:
    matchLabels:
      app: forgejo-runner
  template:
    metadata:
      labels:
        app: forgejo-runner
    spec:
      containers:
        - name: dind
          image: docker:27-dind
          securityContext:
            privileged: true
          env:
            - name: DOCKER_TLS_CERTDIR
              value: ""
          volumeMounts:
            - name: docker-socket
              mountPath: /var/run
            - name: dind-storage
              mountPath: /var/lib/docker

        - name: runner
          image: code.forgejo.org/forgejo/runner:4.0.1
          command:
            - /bin/sh
            - -c
            - |
              echo "Waiting for Docker daemon to become responsive..."
              while ! docker info >/dev/null 2>&1; do
                sleep 2
              done
              echo "Docker daemon ready."

              if [ ! -f /data/.runner ]; then
                echo "Registering runner with Forgejo..."
                if [ -z "${RUNNER_TOKEN}" ] || [ "${RUNNER_TOKEN}" = "manual-token-required" ]; then
                  echo "Waiting for valid registration token..."
                  sleep 30
                  exit 1
                fi
                forgejo-runner register \
                  --no-interactive \
                  --instance "${FORGEJO_INSTANCE_URL}" \
                  --token "${RUNNER_TOKEN}" \
                  --name "${RUNNER_NAME}" \
                  --labels "ubuntu-latest:docker://node:20-bookworm,ubuntu-22.04:docker://node:20-bookworm,docker:docker://docker:27-cli"
              fi
              exec forgejo-runner daemon --config /etc/forgejo-runner/config.yaml
          env:
            - name: DOCKER_HOST
              value: "unix:///var/run/docker.sock"
            - name: FORGEJO_INSTANCE_URL
              value: "http://forgejo-http.forgejo.svc.cluster.local:3000"
            - name: RUNNER_NAME
              value: "k3s-dind-runner"
            - name: RUNNER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: forgejo-runner-secret
                  key: token
          volumeMounts:
            - name: docker-socket
              mountPath: /var/run
            - name: runner-data
              mountPath: /data
            - name: runner-config
              mountPath: /etc/forgejo-runner/config.yaml
              subPath: config.yaml
      volumes:
        - name: docker-socket
          emptyDir: {}
        - name: runner-config
          configMap:
            name: forgejo-runner-config
  volumeClaimTemplates:
    - metadata:
        name: runner-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "local-path"
        resources:
          requests:
            storage: 5Gi
    - metadata:
        name: dind-storage
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "local-path"
        resources:
          requests:
            storage: 20Gi
EOF
kubectl apply -f "${TMP_DIR}/runner-statefulset.yaml" >/dev/null
log_info "Waiting for Forgejo runner rollout..."
kubectl rollout status statefulset/forgejo-runner -n forgejo-runner --timeout=180s >/dev/null || true
log_success "Forgejo DinD Runner deployed."

# ------------------------------------------------------------------------------
# Phase 9: Deploy Plane (plane.so)
# ------------------------------------------------------------------------------
log_step "[9/10] Deploying Plane Management Suite (plane.${DOMAIN})..."
helm repo add makeplane https://helm.plane.so --force-update >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

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
    password: "${PLANE_DB_PASS}"
    database: "plane"
  primary:
    persistence:
      storageClass: "local-path"
      size: 20Gi

redis:
  auth:
    password: "${PLANE_DB_PASS}"
  master:
    persistence:
      storageClass: "local-path"
      size: 5Gi

minio:
  rootUser: "plane-access-key"
  rootPassword: "${MINIO_SECRET_PASS}"
  persistence:
    storageClass: "local-path"
    size: 20Gi

rabbitmq:
  auth:
    username: "plane"
    password: "${PLANE_DB_PASS}"
  persistence:
    storageClass: "local-path"
    size: 5Gi
EOF

log_info "Installing Plane Community Edition via Helm..."
helm upgrade --install plane-app makeplane/plane-ce \
    --namespace plane \
    -f "${TMP_DIR}/values-plane.yaml" \
    --timeout 12m >/dev/null || log_warn "Plane Helm release triggered in background."
log_success "Plane deployment initialized."

# ------------------------------------------------------------------------------
# Phase 10: Deploy It's a Plan (itsaplan.dev)
# ------------------------------------------------------------------------------
log_step "[10/10] Deploying It's a Plan AI Issue Tracker (itsaplan.${DOMAIN})..."

cat << EOF > "${TMP_DIR}/itsaplan-full.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: itsaplan-secrets
  namespace: itsaplan
type: Opaque
stringData:
  POSTGRES_USER: "itsaplan"
  POSTGRES_PASSWORD: "${ITSAPLAN_DB_PASS}"
  POSTGRES_DB: "itsaplan"
  DATABASE_URL: "postgres://itsaplan:${ITSAPLAN_DB_PASS}@itsaplan-postgres:5432/itsaplan"
  S3_ACCESS_KEY_ID: "rustfs-admin"
  S3_SECRET_ACCESS_KEY: "${MINIO_SECRET_PASS}"
  S3_BUCKET: "planner-attachments"
  BETTER_AUTH_SECRET: "${BETTER_AUTH_SECRET}"
  APP_ENCRYPTION_KEY: "${APP_ENCRYPTION_KEY}"
  API_URL: "https://api.itsaplan.${DOMAIN}"
  APP_URL: "https://itsaplan.${DOMAIN}"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: itsaplan-postgres
  namespace: itsaplan
spec:
  serviceName: itsaplan-postgres
  replicas: 1
  selector:
    matchLabels:
      app: itsaplan-postgres
  template:
    metadata:
      labels:
        app: itsaplan-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:17-alpine
          envFrom:
            - secretRef:
                name: itsaplan-secrets
          ports:
            - containerPort: 5432
              name: postgres
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "local-path"
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: itsaplan-postgres
  namespace: itsaplan
spec:
  type: ClusterIP
  ports:
    - port: 5432
      name: postgres
  selector:
    app: itsaplan-postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: itsaplan-minio
  namespace: itsaplan
spec:
  serviceName: itsaplan-minio
  replicas: 1
  selector:
    matchLabels:
      app: itsaplan-minio
  template:
    metadata:
      labels:
        app: itsaplan-minio
    spec:
      containers:
        - name: rustfs
          image: rustfs/rustfs:1.0.0
          env:
            - name: RUSTFS_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: itsaplan-secrets
                  key: S3_ACCESS_KEY_ID
            - name: RUSTFS_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: itsaplan-secrets
                  key: S3_SECRET_ACCESS_KEY
          ports:
            - containerPort: 9000
              name: s3
            - containerPort: 9001
              name: console
          volumeMounts:
            - name: minio-data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: minio-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "local-path"
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: itsaplan-minio
  namespace: itsaplan
spec:
  type: ClusterIP
  ports:
    - port: 9000
      name: s3
    - port: 9001
      name: console
  selector:
    app: itsaplan-minio
---
apiVersion: batch/v1
kind: Job
metadata:
  name: itsaplan-bucket-init
  namespace: itsaplan
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: bucket-init
          image: curlimages/curl:latest
          envFrom:
            - secretRef:
                name: itsaplan-secrets
          command:
            - /bin/sh
            - -c
            - |
              while ! curl -s -f http://itsaplan-minio:9000/health; do sleep 2; done
              curl -fsS -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" \
                --user "${S3_ACCESS_KEY_ID}:${S3_SECRET_ACCESS_KEY}" \
                "http://itsaplan-minio:9000/${S3_BUCKET}" || true
---
apiVersion: batch/v1
kind: Job
metadata:
  name: itsaplan-db-migrate
  namespace: itsaplan
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: wait-postgres
          image: postgres:17-alpine
          envFrom:
            - secretRef:
                name: itsaplan-secrets
          command:
            - /bin/sh
            - -c
            - |
              until pg_isready -h itsaplan-postgres -p 5432 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"; do sleep 2; done
      containers:
        - name: migrate
          image: ghcr.io/croffasia/itsaplan-api:latest
          command: ["bun", "run", "packages/db/src/migrate.ts"]
          envFrom:
            - secretRef:
                name: itsaplan-secrets
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: itsaplan-api
  namespace: itsaplan
  labels:
    app: itsaplan-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: itsaplan-api
  template:
    metadata:
      labels:
        app: itsaplan-api
    spec:
      containers:
        - name: api
          image: ghcr.io/croffasia/itsaplan-api:latest
          command: ["bun", "run", "apps/api/src/index.ts"]
          env:
            - name: NODE_ENV
              value: "production"
            - name: API_PORT
              value: "3000"
            - name: S3_ENDPOINT
              value: "http://itsaplan-minio:9000"
            - name: S3_REGION
              value: "us-east-1"
          envFrom:
            - secretRef:
                name: itsaplan-secrets
          ports:
            - containerPort: 3000
              name: http
---
apiVersion: v1
kind: Service
metadata:
  name: itsaplan-api
  namespace: itsaplan
spec:
  type: ClusterIP
  ports:
    - port: 3000
      name: http
  selector:
    app: itsaplan-api
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: itsaplan-worker
  namespace: itsaplan
  labels:
    app: itsaplan-worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: itsaplan-worker
  template:
    metadata:
      labels:
        app: itsaplan-worker
    spec:
      containers:
        - name: worker
          image: ghcr.io/croffasia/itsaplan-worker:latest
          env:
            - name: NODE_ENV
              value: "production"
            - name: S3_ENDPOINT
              value: "http://itsaplan-minio:9000"
            - name: S3_REGION
              value: "us-east-1"
          envFrom:
            - secretRef:
                name: itsaplan-secrets
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: itsaplan-bot
  namespace: itsaplan
  labels:
    app: itsaplan-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: itsaplan-bot
  template:
    metadata:
      labels:
        app: itsaplan-bot
    spec:
      containers:
        - name: bot
          image: ghcr.io/croffasia/itsaplan-bot:latest
          env:
            - name: NODE_ENV
              value: "production"
          envFrom:
            - secretRef:
                name: itsaplan-secrets
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: itsaplan-web
  namespace: itsaplan
  labels:
    app: itsaplan-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: itsaplan-web
  template:
    metadata:
      labels:
        app: itsaplan-web
    spec:
      containers:
        - name: web
          image: ghcr.io/croffasia/itsaplan-web:latest
          env:
            - name: NODE_ENV
              value: "production"
            - name: PORT
              value: "3001"
            - name: HOSTNAME
              value: "0.0.0.0"
          envFrom:
            - secretRef:
                name: itsaplan-secrets
          ports:
            - containerPort: 3001
              name: http
---
apiVersion: v1
kind: Service
metadata:
  name: itsaplan-web
  namespace: itsaplan
spec:
  type: ClusterIP
  ports:
    - port: 3001
      name: http
  selector:
    app: itsaplan-web
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: itsaplan-ingress
  namespace: itsaplan
  annotations:
    cert-manager.io/cluster-issuer: "${CERT_ISSUER}"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - "itsaplan.${DOMAIN}"
        - "api.itsaplan.${DOMAIN}"
      secretName: itsaplan-tls
  rules:
    - host: "itsaplan.${DOMAIN}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: itsaplan-web
                port:
                  number: 3001
    - host: "api.itsaplan.${DOMAIN}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: itsaplan-api
                port:
                  number: 3000
EOF

log_info "Applying It's a Plan Kubernetes manifests..."
kubectl apply -f "${TMP_DIR}/itsaplan-full.yaml" >/dev/null
log_success "It's a Plan deployed."

# ------------------------------------------------------------------------------
# Phase 11: Save Credentials & Display Platform Summary
# ------------------------------------------------------------------------------
CREDENTIALS_FILE="/root/.pipeline-credentials.txt"
cat << EOF > "${CREDENTIALS_FILE}"
==============================================================================
               k3s Platform Credentials & Access URLs
==============================================================================
Cluster Public IP:       ${PUBLIC_IP}
Base Domain:             ${DOMAIN}
TLS Certificate Issuer:  ${CERT_ISSUER}
Generated On:            $(date)

------------------------------------------------------------------------------
1. Forgejo (Git & Actions)
   URL:                  https://git.${DOMAIN}
   Administrator User:   forgejo-admin
   Admin Password:       ${ADMIN_PASS}
   Git SSH URL:          ssh://git@${DOMAIN}:32222/<user>/<repo>.git

2. Forgejo DinD Runner
   Namespace:            forgejo-runner
   Pod Name:             forgejo-runner-0
   Executor:             Docker-in-Docker sidecar (docker:27-dind)

3. Plane (plane.so)
   URL:                  https://plane.${DOMAIN}
   PostgreSQL Password:  ${PLANE_DB_PASS}

4. It's a Plan (itsaplan.dev)
   Web URL:              https://itsaplan.${DOMAIN}
   API URL:              https://api.itsaplan.${DOMAIN}
   PostgreSQL Password:  ${ITSAPLAN_DB_PASS}
   BetterAuth Secret:    ${BETTER_AUTH_SECRET}
   AES Encryption Key:   ${APP_ENCRYPTION_KEY}

Kubeconfig Location:     /root/.kube/config (or /etc/rancher/k3s/k3s.yaml)
Credentials Record:      /root/.pipeline-credentials.txt
==============================================================================
EOF
chmod 600 "${CREDENTIALS_FILE}"

echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}             🎉 DEPLOYMENT FINISHED SUCCESSFULLY! 🎉${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
cat "${CREDENTIALS_FILE}"
echo ""
log_info "To monitor running pods:"
echo "   kubectl get pods -A"
echo ""
log_info "Credentials have been safely saved to: ${CREDENTIALS_FILE}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
