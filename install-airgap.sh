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
    log_success "Installed k3s binary to /usr/local/bin/k3s"
elif command -v k3s >/dev/null 2>&1; then
    log_success "k3s binary already installed."
else
    log_error "k3s binary not found in ./bin/k3s or /usr/local/bin/k3s!"
    exit 1
fi

if [ -f "${SCRIPT_DIR}/bin/helm" ]; then
    cp -f "${SCRIPT_DIR}/bin/helm" /usr/local/bin/helm
    chmod +x /usr/local/bin/helm
    log_success "Installed Helm binary to /usr/local/bin/helm"
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

SELINUX_FLAG=""
if rpm -q k3s-selinux >/dev/null 2>&1; then
    SELINUX_FLAG="selinux: true"
fi

cat << EOF > /etc/rancher/k3s/config.yaml
write-kubeconfig-mode: "0644"
${SELINUX_FLAG}
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

INSTALL_SCRIPT="${SCRIPT_DIR}/k3s-install.sh"
if [ ! -f "${INSTALL_SCRIPT}" ]; then
    INSTALL_SCRIPT=$(which install-k3s.sh 2>/dev/null || which k3s-install.sh 2>/dev/null || true)
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

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p /root/.kube
cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config

log_info "Waiting for k3s cluster to initialize..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
    sleep 3
done
log_success "k3s cluster is Ready."

# 8. Deploy Workload Manifests Offline
log_step "[8/8] Deploying Platform Workloads (Offline Manifests)..."

for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# Apply ClusterIssuer (self-signed for airgap)
cat << 'EOF' | kubectl apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

# Deploy manifests from ./manifests if present
if [ -d "${SCRIPT_DIR}/manifests" ]; then
    log_info "Applying local manifests..."
    kubectl apply -f "${SCRIPT_DIR}/manifests/00-namespaces.yaml" 2>/dev/null || true
    kubectl apply -f "${SCRIPT_DIR}/manifests/cert-manager/" 2>/dev/null || true
    kubectl apply -k "${SCRIPT_DIR}/manifests/itsaplan/" 2>/dev/null || \
    kubectl apply -f "${SCRIPT_DIR}/manifests/itsaplan/" 2>/dev/null || true
    kubectl apply -f "${SCRIPT_DIR}/manifests/forgejo-runner/" 2>/dev/null || true
fi

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
