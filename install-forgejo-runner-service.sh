#!/usr/bin/env bash
# ==============================================================================
# Forgejo Actions Host Worker Systemd Service Installer & Auto-Registrar
#
# Features:
#   - Installs forgejo-runner binary to /usr/local/bin/forgejo-runner
#     (supports offline extraction from k3s containerd, docker/podman, or web download)
#   - Auto-discovers Forgejo cluster URL & generates registration token via kubectl
#   - Configures native host execution (bare-metal speed + access to host tools)
#   - Creates an idempotent systemd service with automatic pre-start registration
#   - Manages service lifecycle (install, status, restart, uninstall)
#
# Usage:
#   sudo ./install-forgejo-runner-service.sh
#   sudo ./install-forgejo-runner-service.sh --url https://git.example.com --token <TOKEN>
#   sudo ./install-forgejo-runner-service.sh --status
#   sudo ./install-forgejo-runner-service.sh --uninstall
# ==============================================================================
set -euo pipefail

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

RUNNER_BIN="/usr/local/bin/forgejo-runner"
RUNNER_REG_SCRIPT="/usr/local/bin/forgejo-runner-register"
CONFIG_DIR="/etc/forgejo-runner"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
ENV_FILE="${CONFIG_DIR}/runner.env"
DATA_DIR="/var/lib/forgejo-runner"
SERVICE_FILE="/etc/systemd/system/forgejo-runner.service"

FORGEJO_URL=""
MANUAL_TOKEN=""
RUNNER_NAME="$(hostname)-host-worker"
RUNNER_LABELS="ubuntu-latest:host,rhel9:host,linux:host,self-hosted:host,baremetal:host"
SERVICE_USER="root"
CHECK_STATUS=false
DO_UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url|--instance)
            FORGEJO_URL="$2"; shift 2 ;;
        -t|--token)
            MANUAL_TOKEN="$2"; shift 2 ;;
        -n|--name)
            RUNNER_NAME="$2"; shift 2 ;;
        -l|--labels)
            RUNNER_LABELS="$2"; shift 2 ;;
        --user)
            SERVICE_USER="$2"; shift 2 ;;
        -s|--status)
            CHECK_STATUS=true; shift ;;
        --uninstall)
            DO_UNINSTALL=true; shift ;;
        -h|--help)
            cat << 'EOF'
Usage: ./install-forgejo-runner-service.sh [OPTIONS]

Options:
  -u, --url <URL>        Forgejo instance URL (default: auto-detected from k3s Ingress)
  -t, --token <TOKEN>    Registration token (default: auto-fetched via kubectl)
  -n, --name <NAME>      Worker display name (default: <hostname>-host-worker)
  -l, --labels <LABELS>  Worker execution labels (default: ubuntu-latest:host,rhel9:host,linux:host,self-hosted:host,baremetal:host)
  --user <USER>          System user for systemd service (default: root)
  -s, --status           Check current systemd service and registration status
  --uninstall            Stop service, remove systemd unit, and cleanup files
  -h, --help             Show this help message and exit

Examples:
  sudo ./install-forgejo-runner-service.sh
  sudo ./install-forgejo-runner-service.sh --url https://git.cluster.internal
  sudo ./install-forgejo-runner-service.sh --status
  sudo ./install-forgejo-runner-service.sh --uninstall
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Ensure root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error "This script must be executed as root (e.g. sudo $0)"
    exit 1
fi

# Ensure kubeconfig if present
if [ -f /etc/rancher/k3s/k3s.yaml ] && [ -z "${KUBECONFIG:-}" ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /root/.kube/config ] && [ -z "${KUBECONFIG:-}" ]; then
    export KUBECONFIG=/root/.kube/config
fi

# Handle Status Check
if [ "$CHECK_STATUS" = true ]; then
    log_step "Checking Forgejo Host Worker Service Status..."
    if systemctl is-active --quiet forgejo-runner 2>/dev/null; then
        log_success "Service 'forgejo-runner' is active (running)."
    else
        log_warn "Service 'forgejo-runner' is not running."
    fi
    echo ""
    systemctl status forgejo-runner --no-pager || true
    echo ""
    log_info "Recent daemon journal logs:"
    journalctl -u forgejo-runner -n 25 --no-pager || true
    exit 0
fi

# Handle Uninstallation
if [ "$DO_UNINSTALL" = true ]; then
    log_step "Uninstalling Forgejo Runner Systemd Service..."
    systemctl stop forgejo-runner 2>/dev/null || true
    systemctl disable forgejo-runner 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    log_success "Systemd service removed."

    log_info "Cleaning up registration and configuration files..."
    rm -rf "${CONFIG_DIR}"
    rm -rf "${DATA_DIR}"
    rm -f "${RUNNER_REG_SCRIPT}"
    log_success "Forgejo worker successfully uninstalled."
    exit 0
fi

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  ______                            _       _____                               
 |  ____|                          (_)     |  __ \                              
 | |__ ___  _ __ __ _  ___ (_) ___  _  ___ | |__) |   _ _ __  _ __   ___ _ __ 
 |  __/ _ \| '__/ _` |/ _ \ | / _ \| |/ _ \|  _  / | | | '_ \| '_ \ / _ \ '__|
 | | | (_) | | | (_| |  __/_| | (_) | | (_) | | \ \ |_| | | | | | | |  __/ |   
 |_|  \___/|_|  \__, |\___(_) |\___/| |\___/|_|  \_\__,_|_| |_|_| |_|\___|_|   
                 __/ |       _/ |  _/ |                                         
                |___/       |__/  |__/       Host Worker Systemd Automation Engine
EOF
echo -e "${NC}"

# ------------------------------------------------------------------------------
# 1. Binary Installation / Extraction
# ------------------------------------------------------------------------------
log_step "[1/6] Installing 'forgejo-runner' binary..."

INSTALL_NEEDED=true
if [ -x "${RUNNER_BIN}" ]; then
    INSTALLED_VER=$("${RUNNER_BIN}" --version 2>/dev/null || true)
    if [ -n "${INSTALLED_VER}" ]; then
        log_success "Existing binary detected: ${INSTALLED_VER}"
        INSTALL_NEEDED=false
    fi
fi

if [ "$INSTALL_NEEDED" = true ]; then
    # Strategy A: Check local extracted binary
    if [ -x "/tmp/runner-extract/bin/forgejo-runner" ]; then
        log_info "Using pre-extracted binary from /tmp/runner-extract/bin/forgejo-runner..."
        cp -f "/tmp/runner-extract/bin/forgejo-runner" "${RUNNER_BIN}"
    # Strategy B: Offline extraction from local k3s containerd
    elif command -v k3s >/dev/null 2>&1 && k3s ctr images list 2>/dev/null | grep -q "code.forgejo.org/forgejo/runner:4.0.1"; then
        log_info "Extracting binary from offline k3s containerd image 'code.forgejo.org/forgejo/runner:4.0.1'..."
        k3s ctr run --rm code.forgejo.org/forgejo/runner:4.0.1 extract-runner cat /bin/forgejo-runner > "${RUNNER_BIN}" 2>/dev/null || true
    # Strategy C: Offline extraction via docker/podman
    elif command -v docker >/dev/null 2>&1 && docker image inspect code.forgejo.org/forgejo/runner:4.0.1 >/dev/null 2>&1; then
        log_info "Extracting binary from local docker image..."
        CID=$(docker create code.forgejo.org/forgejo/runner:4.0.1 2>/dev/null || true)
        if [ -n "$CID" ]; then
            docker cp "${CID}:/bin/forgejo-runner" "${RUNNER_BIN}" 2>/dev/null || true
            docker rm -f "$CID" >/dev/null 2>&1 || true
        fi
    elif command -v podman >/dev/null 2>&1 && podman image exists code.forgejo.org/forgejo/runner:4.0.1 2>/dev/null; then
        log_info "Extracting binary from local podman image..."
        CID=$(podman create code.forgejo.org/forgejo/runner:4.0.1 2>/dev/null || true)
        if [ -n "$CID" ]; then
            podman cp "${CID}:/bin/forgejo-runner" "${RUNNER_BIN}" 2>/dev/null || true
            podman rm -f "$CID" >/dev/null 2>&1 || true
        fi
    # Strategy D: Direct online download
    else
        log_info "Downloading official static release from code.forgejo.org..."
        curl -fsSL "https://code.forgejo.org/forgejo/runner/releases/download/v4.0.1/forgejo-runner-4.0.1-linux-amd64" -o "${RUNNER_BIN}" || true
    fi

    if [ ! -s "${RUNNER_BIN}" ]; then
        log_error "Could not install 'forgejo-runner' binary to ${RUNNER_BIN}."
        log_info "Please ensure the image 'code.forgejo.org/forgejo/runner:4.0.1' is imported or provide the binary manually."
        exit 1
    fi

    chmod +x "${RUNNER_BIN}"
    log_success "Binary installed successfully: $("${RUNNER_BIN}" --version 2>/dev/null || echo 'ready')"
fi

# ------------------------------------------------------------------------------
# 2. Forgejo Instance URL & Token Discovery
# ------------------------------------------------------------------------------
log_step "[2/6] Discovering Forgejo Instance URL & Registration Token..."

if [ -z "${FORGEJO_URL}" ]; then
    if command -v kubectl >/dev/null 2>&1; then
        DETECTED_DOMAIN=$(kubectl get ingress forgejo -n forgejo -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
        if [ -n "${DETECTED_DOMAIN}" ]; then
            FORGEJO_URL="https://${DETECTED_DOMAIN}"
            log_info "Auto-detected Forgejo instance URL from Ingress: ${FORGEJO_URL}"
        fi
    fi
fi

if [ -z "${FORGEJO_URL}" ]; then
    FORGEJO_URL="http://127.0.0.1:3000"
    log_info "Defaulting Forgejo instance URL to: ${FORGEJO_URL}"
fi

RUNNER_TOKEN="${MANUAL_TOKEN}"
if [ -z "${RUNNER_TOKEN}" ]; then
    if command -v kubectl >/dev/null 2>&1; then
        log_info "Querying Forgejo cluster pod for instance registration token..."
        FORGEJO_POD=$(kubectl get pods -n forgejo -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -z "$FORGEJO_POD" ]; then
            FORGEJO_POD=$(kubectl get pods -n forgejo --no-headers 2>/dev/null | awk '{print $1}' | head -n 1 || true)
        fi

        if [ -n "$FORGEJO_POD" ]; then
            RAW_TOKEN=$(kubectl exec -n forgejo "$FORGEJO_POD" -c forgejo -- gitea actions generate-runner-token 2>/dev/null || \
                        kubectl exec -n forgejo "$FORGEJO_POD" -c forgejo -- forgejo actions generate-runner-token 2>/dev/null || true)
            RUNNER_TOKEN=$(echo "$RAW_TOKEN" | grep -E '^[a-zA-Z0-9]{30,}' | tail -n 1 || true)
            if [ -z "$RUNNER_TOKEN" ]; then
                RUNNER_TOKEN=$(echo "$RAW_TOKEN" | tail -n 1 | tr -d '[:space:]')
            fi
        fi
    fi
fi

if [ -z "${RUNNER_TOKEN}" ]; then
    log_error "No registration token available."
    echo ""
    echo "Please provide your registration token (from Forgejo Web UI -> Admin -> Actions -> Runners -> Create Runner):"
    echo "  sudo ./install-forgejo-runner-service.sh --token <YOUR_TOKEN> --url ${FORGEJO_URL}"
    exit 1
fi

log_success "Registration token acquired: ${RUNNER_TOKEN:0:6}****************"

# ------------------------------------------------------------------------------
# 3. Directory & Configuration Setup
# ------------------------------------------------------------------------------
log_step "[3/6] Setting up runtime directories & configuration..."

mkdir -p "${CONFIG_DIR}"
mkdir -p "${DATA_DIR}"
mkdir -p "${DATA_DIR}/work"
mkdir -p "${DATA_DIR}/cache"

# Generate config.yaml
cat << EOF > "${CONFIG_FILE}"
log:
  level: info

runner:
  file: ${DATA_DIR}/.runner
  capacity: 2
  timeout: 3h
  insecure: true
  fetch_timeout: 5s
  fetch_interval: 2s
  labels: []

cache:
  enabled: true
  dir: ${DATA_DIR}/cache

container:
  network: ""
  privileged: false
  docker_host: ""

host:
  workdir_parent: ${DATA_DIR}/work
EOF
log_success "Config written to: ${CONFIG_FILE}"

# Save environment configuration for systemd unit
cat << EOF > "${ENV_FILE}"
FORGEJO_INSTANCE_URL="${FORGEJO_URL}"
FORGEJO_RUNNER_TOKEN="${RUNNER_TOKEN}"
FORGEJO_RUNNER_NAME="${RUNNER_NAME}"
FORGEJO_RUNNER_LABELS="${RUNNER_LABELS}"
EOF
chmod 0600 "${ENV_FILE}"
log_success "Environment configuration saved to: ${ENV_FILE}"

# ------------------------------------------------------------------------------
# 4. Registration Helper Script
# ------------------------------------------------------------------------------
log_step "[4/6] Creating automatic pre-start registration script..."

cat << 'EOF' > "${RUNNER_REG_SCRIPT}"
#!/usr/bin/env bash
set -euo pipefail

RUNNER_BIN="/usr/local/bin/forgejo-runner"
CONFIG_FILE="/etc/forgejo-runner/config.yaml"
ENV_FILE="/etc/forgejo-runner/runner.env"
DATA_DIR="/var/lib/forgejo-runner"

[ -f "$ENV_FILE" ] && source "$ENV_FILE"

# If already registered, exit immediately
if [ -f "${DATA_DIR}/.runner" ]; then
    echo "Forgejo runner is already registered."
    exit 0
fi

echo "Registering Forgejo host worker with instance: ${FORGEJO_INSTANCE_URL}..."

if [ -z "${FORGEJO_RUNNER_TOKEN:-}" ]; then
    echo "ERROR: FORGEJO_RUNNER_TOKEN is empty! Cannot register." >&2
    exit 1
fi

cd "${DATA_DIR}"

if ! "${RUNNER_BIN}" register \
    --config "${CONFIG_FILE}" \
    --no-interactive \
    --instance "${FORGEJO_INSTANCE_URL}" \
    --token "${FORGEJO_RUNNER_TOKEN}" \
    --name "${FORGEJO_RUNNER_NAME}" \
    --labels "${FORGEJO_RUNNER_LABELS}"; then
    echo "ERROR: 'forgejo-runner register' failed!" >&2
    exit 1
fi

if [ -f .runner ] && [ ! -f "${DATA_DIR}/.runner" ]; then
    cp -f .runner "${DATA_DIR}/.runner"
fi

echo "Forgejo host worker registered successfully."
EOF

chmod +x "${RUNNER_REG_SCRIPT}"
log_success "Registration helper installed to: ${RUNNER_REG_SCRIPT}"

# ------------------------------------------------------------------------------
# 5. Systemd Unit Installation & Activation
# ------------------------------------------------------------------------------
log_step "[5/6] Installing systemd unit 'forgejo-runner.service'..."

cat << EOF > "${SERVICE_FILE}"
[Unit]
Description=Forgejo Actions Host Worker Daemon
Documentation=https://forgejo.org/docs/latest/admin/actions/
After=network-online.target k3s.service docker.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${DATA_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStartPre=${RUNNER_REG_SCRIPT}
ExecStart=${RUNNER_BIN} daemon --config ${CONFIG_FILE}
Restart=always
RestartSec=5s
LimitNOFILE=65536
LimitNPROC=65536
KillMode=process
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

log_info "Reloading systemd daemon and enabling service..."
systemctl daemon-reload
systemctl enable --now forgejo-runner

# ------------------------------------------------------------------------------
# 6. Verification
# ------------------------------------------------------------------------------
log_step "[6/6] Verifying service startup..."
sleep 3

if systemctl is-active --quiet forgejo-runner; then
    echo ""
    echo -e "${GREEN}${BOLD}==============================================================================${NC}"
    echo -e "${GREEN}${BOLD}       ✔ FORGEJO HOST WORKER SYSTEMD SERVICE ACTIVE & RUNNING!${NC}"
    echo -e "${GREEN}${BOLD}==============================================================================${NC}"
    echo -e " Service Name:      ${BOLD}forgejo-runner.service${NC}"
    echo -e " Worker Name:       ${BOLD}${RUNNER_NAME}${NC}"
    echo -e " Target Instance:   ${BOLD}${FORGEJO_URL}${NC}"
    echo -e " Execution Mode:    ${BOLD}Host Native (:host labels)${NC}"
    echo -e " Assigned Labels:   ${CYAN}${RUNNER_LABELS}${NC}"
    echo -e " Working Directory: ${DATA_DIR}"
    echo ""
    echo -e " Commands for management:"
    echo -e "   Status:          sudo systemctl status forgejo-runner"
    echo -e "   Live Logs:       sudo journalctl -u forgejo-runner -f"
    echo -e "   Restart:         sudo systemctl restart forgejo-runner"
    echo -e "   Check in UI:     ${FORGEJO_URL}/admin/actions/runners"
    echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
else
    log_warn "Service was submitted but may still be initializing. Checking journal output:"
    journalctl -u forgejo-runner -n 25 --no-pager || true
fi
