#!/usr/bin/env bash
# ==============================================================================
# k3s Service Diagnostic & Self-Healing Repair Tool
# Diagnoses why k3s.service failed and automatically applies targeted fixes
# for RHEL 9.6 / Rocky 9 / AlmaLinux 9 / CentOS environments.
#
# Usage:
#   sudo ./repair-k3s.sh
# ==============================================================================
set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "\n${BLUE}${BOLD}==============================================================================${NC}"
echo -e "${BLUE}${BOLD}            🩺 k3s Diagnostic & Self-Healing Repair Tool${NC}"
echo -e "${BLUE}${BOLD}==============================================================================${NC}\n"

# ------------------------------------------------------------------------------
# 1. System & Architecture Diagnostics
# ------------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}[1/5] Gathering System Diagnostics...${NC}"
ARCH=$(uname -m)
echo " - Architecture:      ${ARCH}"
if [ -f /etc/os-release ]; then
    OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    echo " - Operating System:  ${OS_NAME}"
fi

SELINUX_STATUS="Disabled"
if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS=$(getenforce)
fi
echo " - SELinux Status:     ${SELINUX_STATUS}"

# Check k3s binary
if [ -f /usr/local/bin/k3s ]; then
    echo " - Binary exists:      /usr/local/bin/k3s ($(du -h /usr/local/bin/k3s | awk '{print $1}'))"
    if ! /usr/local/bin/k3s --version >/dev/null 2>&1; then
        echo -e "${RED}   ✖ /usr/local/bin/k3s CANNOT be executed!${NC}"
        file /usr/local/bin/k3s 2>/dev/null || true
    else
        echo " - Binary version:     $(/usr/local/bin/k3s --version | head -n 1)"
    fi
else
    echo -e "${RED} - /usr/local/bin/k3s is MISSING!${NC}"
fi

# ------------------------------------------------------------------------------
# 2. Inspect Failure Logs
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[2/5] Inspecting Recent k3s Journal Logs...${NC}"
echo "------------------------------------------------------------------------------"
journalctl -u k3s -n 35 --no-pager || true
echo "------------------------------------------------------------------------------"

# ------------------------------------------------------------------------------
# 3. Direct Foreground Test (Captures Hidden Errors)
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[3/5] Testing Direct k3s Server Launch (capturing stderr)...${NC}"
if [ -x /usr/local/bin/k3s ]; then
    TMP_ERR=$(mktemp)
    # Run k3s server directly with a 4-second timeout to capture immediate fatal errors
    timeout 4 /usr/local/bin/k3s server > /dev/null 2> "${TMP_ERR}" || true
    if [ -s "${TMP_ERR}" ]; then
        echo -e "${YELLOW}Captured direct startup output:${NC}"
        grep -E "(FATA|ERRO|WARN|panic|fail|SELinux|denied|bind)" "${TMP_ERR}" | head -n 15 || cat "${TMP_ERR}" | head -n 15
    fi
    rm -f "${TMP_ERR}"
fi

# ------------------------------------------------------------------------------
# 4. Applying Targeted Fixes
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[4/5] Applying Targeted Fixes for Common RHEL 9 Failures...${NC}"

# Fix A: SELinux labeling on binary and state directories
if command -v restorecon >/dev/null 2>&1; then
    echo " -> Restoring SELinux security contexts on /usr/local/bin/k3s and /etc/rancher..."
    restorecon -v /usr/local/bin/k3s >/dev/null 2>&1 || true
    restorecon -R -v /etc/rancher /var/lib/rancher >/dev/null 2>&1 || true
fi

# Fix B: Remove 'selinux: true' from config.yaml if container-selinux causes a crash
if [ -f /etc/rancher/k3s/config.yaml ]; then
    if grep -q "selinux: true" /etc/rancher/k3s/config.yaml; then
        echo " -> Disabling 'selinux: true' in /etc/rancher/k3s/config.yaml to bypass containerd SELinux crash..."
        sed -i '/selinux: true/d' /etc/rancher/k3s/config.yaml
    fi
fi

# Fix C: Ensure required kernel modules are loaded
echo " -> Ensuring br_netfilter and overlay kernel modules are loaded..."
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true

# Fix D: Ensure k3s binary is installed in both /usr/local/bin and /usr/bin
if [ ! -x /usr/local/bin/k3s ]; then
    echo " -> Searching for k3s binary on disk..."
    FOUND_K3S=$(find /root /tmp "${PWD}" -name "k3s" -type f -perm /111 2>/dev/null | head -n 1 || true)
    if [ -n "${FOUND_K3S}" ]; then
        echo " -> Found k3s binary at ${FOUND_K3S}. Installing to /usr/local/bin/k3s and /usr/bin/k3s..."
        cp -f "${FOUND_K3S}" /usr/local/bin/k3s
        chmod +x /usr/local/bin/k3s
    fi
fi

if [ -x /usr/local/bin/k3s ]; then
    cp -f /usr/local/bin/k3s /usr/bin/k3s 2>/dev/null || ln -sf /usr/local/bin/k3s /usr/bin/k3s
    chmod +x /usr/bin/k3s 2>/dev/null || true

    # Provide kubectl, crictl, ctr
    ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
    ln -sf /usr/local/bin/k3s /usr/bin/kubectl
    ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
    ln -sf /usr/local/bin/k3s /usr/bin/crictl
    ln -sf /usr/local/bin/k3s /usr/local/bin/ctr
    ln -sf /usr/local/bin/k3s /usr/bin/ctr

    # Provide k3s-server wrapper for scripts expecting 'k3s-server'
    echo " -> Creating k3s-server wrapper in /usr/bin/k3s-server and /usr/local/bin/k3s-server..."
    cat << 'EOF' > /usr/local/bin/k3s-server
#!/bin/sh
exec /usr/bin/k3s server "$@"
EOF
    chmod +x /usr/local/bin/k3s-server
    ln -sf /usr/local/bin/k3s-server /usr/bin/k3s-server

    # Provide k3s-agent wrapper
    cat << 'EOF' > /usr/local/bin/k3s-agent
#!/bin/sh
exec /usr/bin/k3s agent "$@"
EOF
    chmod +x /usr/local/bin/k3s-agent
    ln -sf /usr/local/bin/k3s-agent /usr/bin/k3s-agent
fi

# Fix E: Ensure systemd unit file is properly structured (and alias k3s-server.service)
if [ ! -f /etc/systemd/system/k3s.service ]; then
    echo " -> Creating missing /etc/systemd/system/k3s.service unit..."
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
ExecStart=/usr/bin/k3s server

[Install]
WantedBy=multi-user.target
EOF
fi

# Ensure ExecStart uses /usr/bin/k3s or /usr/local/bin/k3s reliably
sed -i 's|ExecStart=k3s-server|ExecStart=/usr/bin/k3s server|g' /etc/systemd/system/k3s.service 2>/dev/null || true
sed -i 's|ExecStart=/usr/local/bin/k3s-server|ExecStart=/usr/bin/k3s server|g' /etc/systemd/system/k3s.service 2>/dev/null || true

# Symlink k3s-server.service to k3s.service
ln -sf /etc/systemd/system/k3s.service /etc/systemd/system/k3s-server.service

# Configure global environment for all shells
cat << 'EOF' > /etc/profile.d/k3s.sh
export PATH="/usr/local/bin:/usr/bin:$PATH"
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
EOF
chmod +x /etc/profile.d/k3s.sh

# Fix F: Kill any zombie k3s or containerd processes holding port 6443
if pgrep -x k3s >/dev/null 2>&1; then
    echo " -> Stopping stale k3s processes..."
    systemctl stop k3s 2>/dev/null || true
    pkill -9 -x k3s 2>/dev/null || true
    sleep 2
fi

# ------------------------------------------------------------------------------
# 5. Restarting Service & Verifying Recovery
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[5/5] Restarting k3s Service...${NC}"
systemctl daemon-reload
systemctl enable k3s >/dev/null 2>&1 || true
systemctl restart k3s || systemctl start k3s

echo " -> Waiting up to 30 seconds for k3s cluster to initialize..."
WAIT_RETRIES=15
SUCCESS=false

while [ $WAIT_RETRIES -gt 0 ]; do
    if systemctl is-active --quiet k3s 2>/dev/null; then
        if [ -s /etc/rancher/k3s/k3s.yaml ]; then
            SUCCESS=true
            break
        fi
    fi
    sleep 2
    WAIT_RETRIES=$((WAIT_RETRIES - 1))
done

if [ "$SUCCESS" = true ]; then
    echo ""
    echo -e "${GREEN}${BOLD}==============================================================================${NC}"
    echo -e "${GREEN}${BOLD}           ✔ SUCCESS: k3s.service IS ACTIVE & HEALTHY!${NC}"
    echo -e "${GREEN}${BOLD}==============================================================================${NC}"
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    mkdir -p /root/.kube
    cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config
    chmod 600 /root/.kube/config

    kubectl get nodes
    echo ""
    echo "You can now run: sudo ./deploy-workloads.sh"
    echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
    exit 0
else
    echo ""
    echo -e "${RED}${BOLD}==============================================================================${NC}"
    echo -e "${RED}${BOLD}       ✖ k3s.service failed to become healthy. Systemd Status:${NC}"
    echo -e "${RED}${BOLD}==============================================================================${NC}"
    systemctl status k3s --no-pager || true
    echo ""
    echo -e "${YELLOW}Latest Journal Logs:${NC}"
    journalctl -u k3s -n 30 --no-pager || true
    echo -e "${RED}${BOLD}==============================================================================${NC}\n"
    exit 1
fi
