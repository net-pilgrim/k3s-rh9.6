#!/usr/bin/env bash
# ==============================================================================
# Deploy k3s Cluster & Platform Workloads
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

# Add ~/.local/bin to PATH if present
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "ERROR: ansible-playbook not found. Please run ./scripts/setup-local-tools.sh first."
    exit 1
fi

echo "=============================================================================="
echo "          k3s Platform Deployment Orchestrator"
echo "=============================================================================="
echo "Project Root: ${PROJECT_ROOT}"
echo "Inventory:    inventory/hosts.ini"
echo "Playbook:     site.yml"
echo "=============================================================================="

# Check if inventory has placeholder IP
if grep -q "YOUR_SERVER_IP" inventory/hosts.ini; then
    echo "WARNING: 'YOUR_SERVER_IP' detected in inventory/hosts.ini."
    echo "Please edit inventory/hosts.ini with your actual server IP/hostname and SSH details before proceeding."
    echo ""
    read -p "Do you want to continue anyway for syntax verification? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "==> [1/2] Verifying playbook syntax..."
ansible-playbook -i inventory/hosts.ini site.yml --syntax-check

echo "==> [2/2] Running deployment playbook..."
ansible-playbook -i inventory/hosts.ini site.yml "$@"

echo "=============================================================================="
echo " Deployment completed successfully!"
echo " Check cluster status anytime with: ./scripts/health-check.sh"
echo "=============================================================================="
