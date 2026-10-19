#!/usr/bin/env bash
# ==============================================================================
# Setup Local Environment for k3s Deployment Automation
# ==============================================================================
set -euo pipefail

echo "==> [1/4] Checking Python & Pip..."
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is not installed. Please install python3."
    exit 1
fi

if ! command -v pip >/dev/null 2>&1; then
    echo "ERROR: pip is not installed. Please install python3-pip."
    exit 1
fi

echo "==> [2/4] Installing ansible-core and dependencies for the current user..."
python3 -m pip install --user --break-system-packages ansible-core pyyaml jinja2

# Ensure ~/.local/bin is in PATH for this session
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
    echo "Added $HOME/.local/bin to current PATH."
fi

echo "==> [3/4] Installing required Ansible galaxy collections..."
ansible-galaxy collection install community.general ansible.posix --force

echo "==> [4/4] Verifying tools..."
ansible --version | head -n 2

echo "=============================================================================="
echo " Setup complete! If 'ansible' is not found in new shells, add to ~/.bashrc:"
echo "   export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "=============================================================================="
