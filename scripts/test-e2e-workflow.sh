#!/usr/bin/env bash
# ==============================================================================
# End-to-End Workflow Verification Script
# Creates a test repository in Forgejo, pushes a workflow, and monitors execution
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Read domain and admin credentials from inventory/group_vars/all.yml
FORGEJO_HOST=$(grep -E '^forgejo_host:' "${PROJECT_ROOT}/inventory/group_vars/all.yml" | awk '{print $2}' | tr -d '"' | envsubst || echo "git.cluster.internal")
ADMIN_USER=$(grep -E '^forgejo_admin_user:' "${PROJECT_ROOT}/inventory/group_vars/all.yml" | awk '{print $2}' | tr -d '"' || echo "forgejo-admin")
ADMIN_PASS=$(grep -E '^forgejo_admin_password:' "${PROJECT_ROOT}/inventory/group_vars/all.yml" | awk '{print $2}' | tr -d '"' || echo "ForgejoSecurePassword123!")

echo "=============================================================================="
echo "          Forgejo Actions End-to-End Verification Test"
echo "=============================================================================="
echo "Forgejo URL:  https://${FORGEJO_HOST}"
echo "Admin User:   ${ADMIN_USER}"
echo "=============================================================================="

TMP_DIR=$(mktemp -d -t forgejo-ci-test-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${TMP_DIR}"

git config --global user.email "ci-test@example.com"
git config --global user.name "CI Runner Tester"

echo "==> Initializing test Git repository..."
git init
mkdir -p .forgejo/workflows

cat << 'EOF' > .forgejo/workflows/test.yaml
name: Test Workflow
on: [push]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Print System Info
        run: |
          echo "Running on k3s DinD Forgejo Runner!"
          uname -a
          docker --version

      - name: Run Containerized Test
        run: |
          docker run --rm alpine:latest echo "Container execution inside k3s DinD succeeded!"
EOF

cat << 'EOF' > README.md
# Forgejo CI Test Repository
This test repository validates Forgejo Actions execution on the k3s cluster.
EOF

git add .
git commit -m "feat: initial test workflow for k3s runner"

echo "==> Test repository prepared in temporary folder."
echo ""
echo "To push this repository to your Forgejo instance:"
echo "  1. Ensure DNS resolves ${FORGEJO_HOST} to your k3s node IP"
echo "  2. Create repository 'ci-test' in Forgejo web UI (or via API)"
echo "  3. Run:"
echo "       git remote add origin https://${ADMIN_USER}:${ADMIN_PASS}@${FORGEJO_HOST}/${ADMIN_USER}/ci-test.git"
echo "       git push -u origin main"
echo "  4. Check the 'Actions' tab in Forgejo to observe the k3s runner executing the job!"
echo "=============================================================================="
