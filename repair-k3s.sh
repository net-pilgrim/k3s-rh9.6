#!/usr/bin/env bash
# ==============================================================================
# k3s Service Diagnostic & Self-Healing Repair Tool
# Fixes "k3s-server argument list too long" recursion loop, wipes corrupted
# self-extraction data cache, and restores k3s.service on RHEL 9.6.
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

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}✖ ERROR: This script must be run as root (e.g. sudo ./repair-k3s.sh)${NC}" >&2
    exit 1
fi

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

# Check for noexec mount on /var or /var/lib
if mount | grep -E '\s(/var|/var/lib)\s.*noexec' >/dev/null 2>&1; then
    echo -e "${YELLOW} - /var mount flag:    WARNING: mounted with 'noexec'!${NC}"
else
    echo " - /var mount flag:    exec allowed"
fi

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

# Check for rogue wrapper scripts that cause recursion loops
if [ -f /usr/local/bin/k3s-server ] || [ -f /usr/bin/k3s-server ]; then
    echo -e "${YELLOW} - Rogue wrappers:     DETECTED (this causes 'argument list too long')${NC}"
fi

# ------------------------------------------------------------------------------
# 2. Emergency Cleanup: Kill Processes & Remove Recursive Wrappers
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[2/5] Cleaning Up Rogue Files, Stale Processes & Corrupt Cache...${NC}"

# A: Stop services and kill lingering processes
echo " -> Stopping k3s service and killing stale processes..."
systemctl stop k3s 2>/dev/null || true
systemctl stop k3s-server 2>/dev/null || true
pkill -9 -x k3s 2>/dev/null || true
pkill -9 -x containerd 2>/dev/null || true
sleep 1

# B: CRITICAL: Remove rogue wrapper scripts causing the recursion bomb!
# When k3s executes, it self-extracts and runs its internal server component.
# A script named 'k3s-server' calling 'k3s server' creates an infinite loop that
# exhausts kernel argument space (E2BIG: Argument list too long).
echo " -> Eliminating rogue wrapper scripts..."
rm -f /usr/local/bin/k3s-server /usr/bin/k3s-server
rm -f /usr/local/bin/k3s-agent /usr/bin/k3s-agent
rm -f /etc/systemd/system/k3s-server.service

# C: CRITICAL: Wipe corrupted self-extraction cache and locks!
# If a previous start was killed or blocked by SELinux, a broken directory in
# /var/lib/rancher/k3s/data blocks subsequent extractions, resulting in:
# "k3s-server: executable file not found in $PATH".
echo " -> Wiping stale k3s extraction cache (/var/lib/rancher/k3s/data)..."
rm -rf /var/lib/rancher/k3s/data
rm -f /var/lib/rancher/k3s/.lock
rm -f /var/lib/rancher/k3s/data/.lock

# ------------------------------------------------------------------------------
# 3. Applying System, Filesystem & SELinux Fixes
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[3/5] Applying System, Filesystem & SELinux Fixes...${NC}"

# Fix A: If /var is mounted noexec, remount it with exec
if mount | grep -E '\s(/var|/var/lib)\s.*noexec' >/dev/null 2>&1; then
    echo " -> Remounting /var with 'exec' permissions..."
    mount -o remount,exec /var 2>/dev/null || true
fi

# Fix B: Ensure kernel modules are loaded
echo " -> Ensuring br_netfilter and overlay kernel modules are loaded..."
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true

# Fix C: Disable 'selinux: true' in config.yaml if present (prevents containerd crash on RHEL 9)
if [ -f /etc/rancher/k3s/config.yaml ]; then
    if grep -q "selinux: true" /etc/rancher/k3s/config.yaml; then
        echo " -> Disabling 'selinux: true' in /etc/rancher/k3s/config.yaml..."
        sed -i '/selinux: true/d' /etc/rancher/k3s/config.yaml
    fi
fi

# Fix D: Ensure k3s binary is valid in /usr/local/bin and /usr/bin
if [ ! -x /usr/local/bin/k3s ]; then
    echo " -> Searching for k3s binary on disk..."
    FOUND_K3S=$(find /root /tmp "${PWD}" -name "k3s" -type f -perm /111 2>/dev/null | head -n 1 || true)
    if [ -n "${FOUND_K3S}" ]; then
        echo " -> Found k3s binary at ${FOUND_K3S}. Installing to /usr/local/bin/k3s..."
        cp -f "${FOUND_K3S}" /usr/local/bin/k3s
        chmod +x /usr/local/bin/k3s
    fi
fi

if [ -x /usr/local/bin/k3s ]; then
    cp -f /usr/local/bin/k3s /usr/bin/k3s 2>/dev/null || ln -sf /usr/local/bin/k3s /usr/bin/k3s
    chmod +x /usr/bin/k3s 2>/dev/null || true

    # Provide kubectl, crictl, ctr multicall links ONLY
    echo " -> Linking CLI tools (kubectl, crictl, ctr)..."
    ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
    ln -sf /usr/local/bin/k3s /usr/bin/kubectl
    ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
    ln -sf /usr/local/bin/k3s /usr/bin/crictl
    ln -sf /usr/local/bin/k3s /usr/local/bin/ctr
    ln -sf /usr/local/bin/k3s /usr/bin/ctr
fi

# Fix E: SELinux labeling on binaries and state directories
if command -v restorecon >/dev/null 2>&1; then
    echo " -> Restoring SELinux security contexts on binaries and directories..."
    chcon -t bin_t /usr/local/bin/k3s /usr/bin/k3s 2>/dev/null || true
    restorecon -v /usr/local/bin/k3s /usr/bin/k3s >/dev/null 2>&1 || true
    mkdir -p /var/lib/rancher /etc/rancher
    restorecon -R -v /etc/rancher /var/lib/rancher >/dev/null 2>&1 || true
fi

# Fix F: Re-create standard systemd unit file
echo " -> Writing clean /etc/systemd/system/k3s.service unit..."
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

# Ensure global profile
cat << 'EOF' > /etc/profile.d/k3s.sh
export PATH="/usr/local/bin:/usr/bin:$PATH"
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi
EOF
chmod +x /etc/profile.d/k3s.sh

# ------------------------------------------------------------------------------
# 4. Direct Foreground Test (Verifies Clean Self-Extraction)
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[4/5] Testing Direct k3s Server Launch & Clean Extraction...${NC}"
if [ -x /usr/local/bin/k3s ]; then
    TMP_ERR=$(mktemp)
    echo " -> Running '/usr/local/bin/k3s server' for 4 seconds to test self-extraction..."
    timeout 4 /usr/local/bin/k3s server > /dev/null 2> "${TMP_ERR}" || true
    if [ -s "${TMP_ERR}" ]; then
        if grep -q -E "(Argument list too long|executable file not found in \$PATH)" "${TMP_ERR}"; then
            echo -e "${RED}✖ FATAL: k3s still reported extraction failure:${NC}"
            cat "${TMP_ERR}"
            rm -f "${TMP_ERR}"
            exit 1
        else
            echo -e "${GREEN}✔ Self-extraction succeeded without recursion or missing binary errors.${NC}"
        fi
    else
        echo -e "${GREEN}✔ Direct startup check passed cleanly.${NC}"
    fi
    rm -f "${TMP_ERR}"
fi

# ------------------------------------------------------------------------------
# 5. Starting Service & Verifying Cluster Health
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}${BOLD}[5/5] Starting k3s Systemd Service...${NC}"
systemctl daemon-reload
systemctl enable k3s >/dev/null 2>&1 || true
systemctl restart k3s || systemctl start k3s

echo " -> Waiting up to 35 seconds for k3s cluster to initialize..."
WAIT_RETRIES=18
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

    /usr/local/bin/kubectl get nodes || /usr/bin/kubectl get nodes
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
    journalctl -u k3s -n 35 --no-pager || true
    echo -e "${RED}${BOLD}==============================================================================${NC}\n"
    exit 1
fi
