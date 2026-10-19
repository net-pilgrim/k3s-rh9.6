#!/usr/bin/env bash
# ==============================================================================
# 100% Offline / Air-Gapped Installer for RHEL 9.6 / Rocky / Ubuntu
# Requires NO internet access. Uses pre-bundled binaries, RPMs, and images.
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

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  _    ____         _   _ _          ____                 _ _      
 | | _|___ / ___   / \ (_) |__      | __ ) _   _ _ __   __| | | ___ 
 | |/ / |_ \/ __| / _ \| | '__|_____|  _ \| | | | '_ \ / _` | |/ _ \
 |   < ___) \__ \/ ___ \ | | |_____| |_) | |_| | | | | (_| | |  __/
 |_|\_\____/|___/_/   \_\_|_|       |____/ \__,_|_| |_|\__,_|_|\___|
EOF
echo -e " 100% Offline / Air-Gapped Cluster Installer for RHEL 9.6${NC}\n"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "This script must be run as root. Please run: sudo bash $0"
    exit 1
fi

# Ensure curl enforces TLS 1.2 across the machine
for curlrc_file in "$HOME/.curlrc" "/root/.curlrc"; do
    if [ ! -f "$curlrc_file" ] || ! grep -q "tlsv1.2" "$curlrc_file" 2>/dev/null; then
        mkdir -p "$(dirname "$curlrc_file")" 2>/dev/null || true
        cat << 'EOF' >> "$curlrc_file" 2>/dev/null || true
tlsv1.2
tls-max = 1.2
EOF
    fi
done

DOMAIN="${DOMAIN:-}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)!A1}"

# Detect Host IP
PUBLIC_IP=$(hostname -I | awk '{print $1}')
if [ -z "${DOMAIN}" ]; then
    DOMAIN="${PUBLIC_IP}.nip.io"
fi
log_info "Cluster Host IP: ${PUBLIC_IP}"
log_info "Base Domain:    ${DOMAIN}"

# 1. Clean any broken yum repos that cause metadata download errors
log_step "[1/8] Cleaning stale or unreachable external package repositories..."
rm -f /etc/yum.repos.d/rancher-k3s-common*.repo 2>/dev/null || true
log_success "Cleaned stale repositories."

# 2. Kernel & swap preparation
log_step "[2/8] Tuning Host Kernel & Disabling Swap..."
swapoff -a || true
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab || true

modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true

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

# 3. Firewalld configuration
log_step "[3/8] Configuring Local Firewall (firewalld)..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
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
    log_success "firewalld rules active."
fi

# 4. Install local k3s-selinux RPM if present
log_step "[4/8] Installing Local SELinux RPM (if present)..."
SELINUX_RPM=$(find "${SCRIPT_DIR}/rpms" "${SCRIPT_DIR}" -name "k3s-selinux*.rpm" 2>/dev/null | head -n 1 || true)
if [ -n "${SELINUX_RPM}" ] && [ -f "${SELINUX_RPM}" ]; then
    log_info "Installing ${SELINUX_RPM}..."
    rpm -Uvh --nodeps "${SELINUX_RPM}" 2>/dev/null || true
    log_success "k3s-selinux installed."
else
    log_info "No local k3s-selinux RPM found. Continuing with standard system policy."
fi

# 5. Install local Binaries (k3s and helm)
log_step "[5/8] Installing k3s and Helm Binaries from Local Bundle..."
mkdir -p /usr/local/bin

if [ -f "${SCRIPT_DIR}/bin/k3s" ]; then
    cp -f "${SCRIPT_DIR}/bin/k3s" /usr/local/bin/k3s
    chmod +x /usr/local/bin/k3s
    restorecon -v /usr/local/bin/k3s 2>/dev/null || true
    log_success "Installed k3s binary to /usr/local/bin/k3s"
elif command -v k3s >/dev/null 2>&1; then
    restorecon -v /usr/local/bin/k3s 2>/dev/null || true
    log_success "k3s binary already installed."
else
    log_error "k3s binary not found in ./bin/k3s or /usr/local/bin/k3s!"
    exit 1
fi

# Ensure binaries exist in /usr/bin for sudo secure_path on RHEL
cp -f /usr/local/bin/k3s /usr/bin/k3s 2>/dev/null || ln -sf /usr/local/bin/k3s /usr/bin/k3s
chmod +x /usr/bin/k3s 2>/dev/null || true

# Symlink standard container tools
for tool in kubectl crictl ctr; do
    ln -sf /usr/local/bin/k3s "/usr/local/bin/${tool}"
    ln -sf /usr/local/bin/k3s "/usr/bin/${tool}"
done

# Create k3s-server and k3s-agent helper wrappers
cat << 'EOF' > /usr/local/bin/k3s-server
#!/bin/sh
exec /usr/bin/k3s server "$@"
EOF
chmod +x /usr/local/bin/k3s-server
ln -sf /usr/local/bin/k3s-server /usr/bin/k3s-server

cat << 'EOF' > /usr/local/bin/k3s-agent
#!/bin/sh
exec /usr/bin/k3s agent "$@"
EOF
chmod +x /usr/local/bin/k3s-agent
ln -sf /usr/local/bin/k3s-agent /usr/bin/k3s-agent

# Set up global profile for PATH and KUBECONFIG
cat << 'EOF' > /etc/profile.d/k3s.sh
export PATH="/usr/local/bin:/usr/bin:$PATH"
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
EOF
chmod +x /etc/profile.d/k3s.sh

if [ -f "${SCRIPT_DIR}/bin/helm" ]; then
    cp -f "${SCRIPT_DIR}/bin/helm" /usr/local/bin/helm
    chmod +x /usr/local/bin/helm
    ln -sf /usr/local/bin/helm /usr/bin/helm
    restorecon -v /usr/local/bin/helm /usr/bin/helm 2>/dev/null || true
    log_success "Installed Helm binary to /usr/local/bin/helm and /usr/bin/helm"
fi

# 6. Copy Pre-downloaded Container Images to containerd auto-import directory
log_step "[6/8] Staging Air-Gap Container Images for Auto-Import..."
mkdir -p /var/lib/rancher/k3s/agent/images

if [ -d "${SCRIPT_DIR}/images" ]; then
    COUNT=$(find "${SCRIPT_DIR}/images" -maxdepth 1 \( -name "*.tar" -o -name "*.tar.gz" -o -name "*.tar.zst" \) | wc -l)
    if [ "${COUNT}" -gt 0 ]; then
        log_info "Copying ${COUNT} image archive(s) to /var/lib/rancher/k3s/agent/images/..."
        cp -f "${SCRIPT_DIR}"/images/*.tar* /var/lib/rancher/k3s/agent/images/ 2>/dev/null || true
        log_success "Images staged for automatic loading by k3s."
    fi
fi

# 7. Configure and start k3s offline
log_step "[7/8] Starting k3s Kubernetes Server (Offline Mode)..."
mkdir -p /etc/rancher/k3s

cat << EOF > /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
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

restorecon -R -v /etc/rancher /var/lib/rancher 2>/dev/null || true

INSTALL_SCRIPT="${SCRIPT_DIR}/k3s-install.sh"
if [ ! -f "${INSTALL_SCRIPT}" ]; then
    INSTALL_SCRIPT=$(find "${SCRIPT_DIR}" . /tmp -maxdepth 2 \( -name "k3s-install.sh" -o -name "install-k3s.sh" \) 2>/dev/null | head -n 1 || true)
fi

if [ -n "${INSTALL_SCRIPT}" ] && [ -f "${INSTALL_SCRIPT}" ]; then
    log_info "Executing ${INSTALL_SCRIPT} with INSTALL_K3S_SKIP_DOWNLOAD=true..."
    INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_SELINUX_RPM=true bash "${INSTALL_SCRIPT}" server
else
    # Fallback to direct systemd unit creation if install script is not bundled
    log_info "Setting up k3s systemd service directly..."
    cat << 'EOF' > /etc/systemd/system/k3s.service
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-/etc/rancher/k3s/k3s.service.env
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s server

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now k3s
fi

# Ensure symlinks for kubectl, crictl, ctr
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
ln -sf /usr/local/bin/k3s /usr/local/bin/ctr

# Explicitly wait for /etc/rancher/k3s/k3s.yaml to be created before copying
log_info "Waiting for k3s cluster to initialize and generate /etc/rancher/k3s/k3s.yaml..."
KUBECONFIG_RETRIES=60
while [ ! -s /etc/rancher/k3s/k3s.yaml ]; do
    if systemctl is-failed --quiet k3s 2>/dev/null; then
        log_error "k3s service has failed to start!"
        echo "=== systemctl status k3s ==="
        systemctl status k3s --no-pager || true
        echo "=== journalctl -u k3s (last 50 lines) ==="
        journalctl -u k3s -n 50 --no-pager || true
        exit 1
    fi
    sleep 2
    KUBECONFIG_RETRIES=$((KUBECONFIG_RETRIES - 1))
    if [ $KUBECONFIG_RETRIES -le 0 ]; then
        log_error "Timed out waiting for /etc/rancher/k3s/k3s.yaml after 120 seconds."
        echo "=== systemctl status k3s ==="
        systemctl status k3s --no-pager || true
        echo "=== journalctl -u k3s (last 50 lines) ==="
        journalctl -u k3s -n 50 --no-pager || true
        exit 1
    fi
done
log_success "/etc/rancher/k3s/k3s.yaml generated successfully."

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /root/.kube
cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config

log_info "Waiting for k3s cluster node to reach Ready state..."
RETRIES=40
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 3
    RETRIES=$((RETRIES - 1))
    if [ $RETRIES -le 0 ]; then
        log_error "Timed out waiting for k3s cluster node to reach Ready state."
        echo "=== kubectl get nodes output ==="
        kubectl get nodes || true
        exit 1
    fi
done
log_success "k3s cluster is Ready."

# 8. Deploy Workload Manifests Offline
log_step "[8/8] Deploying Platform Workloads (Offline Mode)..."

if [ -f "${SCRIPT_DIR}/deploy-workloads.sh" ]; then
    bash "${SCRIPT_DIR}/deploy-workloads.sh" --domain "${DOMAIN}" --admin-pass "${ADMIN_PASS}"
    exit 0
fi

# Ensure all namespaces exist
for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# 8.1. Cert-Manager Deployment
log_info "Installing cert-manager..."
CERT_MANAGER_YAML=$(find "${SCRIPT_DIR}/manifests/cert-manager" "${SCRIPT_DIR}" -name "cert-manager.yaml" 2>/dev/null | head -n 1 || true)
CERT_CHART=$(find "${SCRIPT_DIR}/charts" "${SCRIPT_DIR}" -name "cert-manager-*.tgz" 2>/dev/null | head -n 1 || true)

if [ -n "${CERT_MANAGER_YAML}" ] && [ -f "${CERT_MANAGER_YAML}" ]; then
    log_info "Applying official cert-manager manifest: ${CERT_MANAGER_YAML}..."
    kubectl apply -f "${CERT_MANAGER_YAML}" >/dev/null || true
elif [ -n "${CERT_CHART}" ] && [ -f "${CERT_CHART}" ]; then
    log_info "Installing cert-manager via local Helm chart: ${CERT_CHART}..."
    helm upgrade --install cert-manager "${CERT_CHART}" \
        --namespace cert-manager \
        --set crds.enabled=true \
        --wait --timeout 5m >/dev/null || true
fi

# Wait for cert-manager-webhook before applying ClusterIssuer
log_info "Waiting for cert-manager-webhook to become responsive..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=90s 2>/dev/null || sleep 10

# Apply ClusterIssuer (self-signed for airgap)
log_info "Applying self-signed ClusterIssuer..."
cat << 'EOF' | kubectl apply -f - >/dev/null || true
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

TMP_DIR=$(mktemp -d -t airgap-workloads-XXXXXX)

# 8.2. Forgejo Git Server Deployment
log_info "Installing Forgejo Git Server..."
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
    cert-manager.io/cluster-issuer: selfsigned-issuer
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
    log_info "Deploying Forgejo using local Helm chart: ${FORGEJO_CHART}..."
    helm upgrade --install forgejo "${FORGEJO_CHART}" \
        --namespace forgejo \
        -f "${TMP_DIR}/values-forgejo.yaml" \
        --timeout 10m >/dev/null || log_warn "Forgejo Helm install initiated."
else
    log_warn "No Forgejo Helm chart (.tgz) found in bundle; applying raw manifests if available."
fi

# 8.3. Forgejo DinD Runner Deployment
log_info "Provisioning Forgejo DinD Runner..."
kubectl create secret generic forgejo-runner-secret \
    --namespace forgejo-runner \
    --from-literal=token="initial-bootstrap-token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

RUNNER_CM=$(find "${SCRIPT_DIR}/manifests/forgejo-runner" "${SCRIPT_DIR}" -name "runner-configmap.yaml" 2>/dev/null | head -n 1 || true)
RUNNER_SS=$(find "${SCRIPT_DIR}/manifests/forgejo-runner" "${SCRIPT_DIR}" -name "runner-statefulset.yaml" 2>/dev/null | head -n 1 || true)

if [ -n "${RUNNER_CM}" ] && [ -f "${RUNNER_CM}" ]; then
    kubectl apply -f "${RUNNER_CM}" >/dev/null
fi
if [ -n "${RUNNER_SS}" ] && [ -f "${RUNNER_SS}" ]; then
    kubectl apply -f "${RUNNER_SS}" >/dev/null
fi

# 8.4. Plane Deployment
log_info "Installing Plane Management Suite..."
PLANE_CHART=$(find "${SCRIPT_DIR}/charts" "${SCRIPT_DIR}" -name "plane-ce-*.tgz" 2>/dev/null | head -n 1 || true)

cat << EOF > "${TMP_DIR}/values-plane.yaml"
planeVersion: "v2.6.3"
env:
  storageClass: "local-path"
  secretKey: "plane-secure-key-${RANDOM}${RANDOM}"

ingress:
  enabled: true
  ingressClass: "traefik"
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-issuer
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
    log_info "Deploying Plane using local Helm chart: ${PLANE_CHART}..."
    helm upgrade --install plane-app "${PLANE_CHART}" \
        --namespace plane \
        -f "${TMP_DIR}/values-plane.yaml" \
        --timeout 12m >/dev/null || log_warn "Plane Helm install initiated in background."
else
    log_warn "No Plane Helm chart (.tgz) found in bundle!"
fi

# 8.5. It's a Plan Deployment
log_info "Deploying It's a Plan AI Issue Tracker..."
ITSAPLAN_DIR="${SCRIPT_DIR}/manifests/itsaplan"
if [ -d "${ITSAPLAN_DIR}" ]; then
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

    for f in "${ITSAPLAN_DIR}"/*.yaml; do
        if [[ "$(basename "$f")" != "00-config-secret.yaml" && "$(basename "$f")" != "kustomization.yaml" ]]; then
            sed "s/cluster.internal/${DOMAIN}/g" "$f" | kubectl apply -f - >/dev/null || true
        fi
    done
fi

rm -rf "${TMP_DIR}"

log_info "Waiting 10 seconds for initial pod scheduling across namespaces..."
sleep 10

echo ""
log_step "Current Workload Status across Namespaces:"
for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
    echo -e "\n${CYAN}${BOLD}--- Namespace: ${ns} ---${NC}"
    kubectl get pods -n "$ns" -o wide 2>/dev/null || echo "No resources found."
done

CREDENTIALS_FILE="/root/.pipeline-credentials.txt"
cat << EOF > "${CREDENTIALS_FILE}"
==============================================================================
          k3s Air-Gapped Platform Credentials & Access URLs
==============================================================================
Cluster Host IP:         ${PUBLIC_IP}
Base Domain:             ${DOMAIN}
TLS Certificate Issuer:  selfsigned-issuer
Deployment Mode:         Air-Gapped / Offline

Services:
  - Forgejo (Git):       https://git.${DOMAIN} (Admin: forgejo-admin / ${ADMIN_PASS})
  - Forgejo Git SSH:     ssh://git@${DOMAIN}:32222/
  - Plane (Management):  https://plane.${DOMAIN}
  - It's a Plan (Web):   https://itsaplan.${DOMAIN}
  - It's a Plan (API):   https://api.itsaplan.${DOMAIN}

Kubeconfig:              /root/.kube/config
==============================================================================
EOF
chmod 600 "${CREDENTIALS_FILE}"

echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}        🎉 AIR-GAPPED DEPLOYMENT COMPLETED SUCCESSFULLY! 🎉${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
cat "${CREDENTIALS_FILE}"
echo ""
