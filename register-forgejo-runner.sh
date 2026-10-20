#!/usr/bin/env bash
# ==============================================================================
# Forgejo Actions Runner Registration & Health Engine
# Automatically extracts instance token from Forgejo, configures the runner secret,
# configures Docker-in-Docker via localhost TCP (2375), and bootstraps the runner.
#
# Usage:
#   sudo ./register-forgejo-runner.sh
#   curl -fsSL https://gist.githubusercontent.com/... | sudo bash
# ==============================================================================
set -eo pipefail

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

RUNNER_NAME="${RUNNER_NAME:-k3s-dind-runner}"
MANUAL_TOKEN=""
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--token)
            MANUAL_TOKEN="$2"; shift 2 ;;
        -n|--name)
            RUNNER_NAME="$2"; shift 2 ;;
        -s|--status)
            CHECK_ONLY=true; shift ;;
        -h|--help)
            cat << 'EOF'
Usage: ./register-forgejo-runner.sh [OPTIONS]

Options:
  -t, --token <TOKEN>    Use an explicit registration token instead of auto-fetching from Forgejo
  -n, --name <NAME>      Set runner display name (default: k3s-dind-runner)
  -s, --status           Check current runner registration status without re-registering
  -h, --help             Show this help message and exit

Examples:
  sudo ./register-forgejo-runner.sh
  sudo ./register-forgejo-runner.sh --status
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$CHECK_ONLY" = true ]; then
    log_step "Checking Forgejo Runner status..."
    kubectl get pods -n forgejo-runner -o wide
    echo ""
    log_info "Recent Runner daemon logs:"
    kubectl logs -n forgejo-runner statefulset/forgejo-runner -c runner --tail=25 || true
    exit 0
fi

log_step "Locating Forgejo instance pod..."
FORGEJO_POD=$(kubectl get pods -n forgejo -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$FORGEJO_POD" ]; then
    FORGEJO_POD=$(kubectl get pods -n forgejo --no-headers 2>/dev/null | awk '{print $1}' | head -n 1 || true)
fi

if [ -z "$FORGEJO_POD" ]; then
    log_error "No Forgejo pod found in namespace 'forgejo'. Is Forgejo deployed?"
    exit 1
fi

log_info "Found Forgejo pod: ${FORGEJO_POD}"

RUNNER_TOKEN="$MANUAL_TOKEN"
if [ -z "$RUNNER_TOKEN" ]; then
    log_step "Querying Forgejo CLI for instance registration token..."
    for i in $(seq 1 15); do
        RAW_TOKEN=$(kubectl exec -n forgejo "$FORGEJO_POD" -c forgejo -- gitea actions generate-runner-token 2>/dev/null || \
                    kubectl exec -n forgejo "$FORGEJO_POD" -c forgejo -- forgejo actions generate-runner-token 2>/dev/null || true)
        RUNNER_TOKEN=$(echo "$RAW_TOKEN" | grep -E '^[a-zA-Z0-9]{30,}' | tail -n 1 || true)
        if [ -z "$RUNNER_TOKEN" ]; then
            RUNNER_TOKEN=$(echo "$RAW_TOKEN" | tail -n 1 | tr -d '[:space:]')
        fi
        if [ -n "$RUNNER_TOKEN" ]; then
            break
        fi
        sleep 2
    done
fi

if [ -z "$RUNNER_TOKEN" ]; then
    log_error "Could not generate runner registration token from Forgejo pod '${FORGEJO_POD}'."
    log_info "Verify Forgejo is running: kubectl get pods -n forgejo"
    exit 1
fi

log_success "Registration token acquired: ${RUNNER_TOKEN:0:6}****************"

log_step "Updating 'forgejo-runner-secret'..."
kubectl create secret generic forgejo-runner-secret \
    --namespace forgejo-runner \
    --from-literal=token="${RUNNER_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log_success "Secret 'forgejo-runner-secret' updated successfully."

log_step "Recreating StatefulSet definition (clearing immutability lock)..."
kubectl delete statefulset forgejo-runner -n forgejo-runner --cascade=orphan --ignore-not-found=true >/dev/null 2>&1 || true

log_step "Applying TCP-based Docker configuration & updated runner manifest..."
cat << 'EOF' | kubectl apply -f -
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
      insecure: true
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
      docker_host: "tcp://127.0.0.1:2375"
---
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
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          env:
            - name: DOCKER_TLS_CERTDIR
              value: ""
          volumeMounts:
            - name: dind-storage
              mountPath: /var/lib/docker

        - name: runner
          image: code.forgejo.org/forgejo/runner:4.0.1
          imagePullPolicy: IfNotPresent
          workingDir: /data
          securityContext:
            runAsUser: 0
          command:
            - /bin/sh
            - -c
            - |
              cd /data
              echo "Waiting for Docker daemon on 127.0.0.1:2375..."
              for i in $(seq 1 30); do
                if wget -q -O - http://127.0.0.1:2375/_ping >/dev/null 2>&1 || \
                   wget -q -O - http://localhost:2375/_ping >/dev/null 2>&1 || \
                   nc -z 127.0.0.1 2375 2>/dev/null; then
                  echo "Docker daemon verified ready on TCP port 2375!"
                  break
                fi
                sleep 1
              done

              echo "Testing Forgejo connectivity at ${FORGEJO_INSTANCE_URL}..."
              wget -q -O - "${FORGEJO_INSTANCE_URL}/api/v1/version" || echo "(Forgejo API probe returned non-200, proceeding with registration...)"

              if [ ! -f /data/.runner ] && [ ! -f .runner ] && [ ! -f /.runner ]; then
                echo "Registering runner with Forgejo at ${FORGEJO_INSTANCE_URL}..."
                if [ -z "${RUNNER_TOKEN}" ]; then
                  echo "ERROR: RUNNER_TOKEN is empty! Please register the runner or populate the secret."
                  sleep 30
                  exit 1
                fi
                if ! forgejo-runner register \
                  --config /etc/forgejo-runner/config.yaml \
                  --no-interactive \
                  --instance "${FORGEJO_INSTANCE_URL}" \
                  --token "${RUNNER_TOKEN}" \
                  --name "${RUNNER_NAME}" \
                  --labels "ubuntu-latest:docker://node:20-bookworm,ubuntu-22.04:docker://node:20-bookworm,docker:docker://docker:27-cli"; then
                  echo "ERROR: forgejo-runner register with config failed! Retrying directly in /data..."
                  forgejo-runner register \
                    --no-interactive \
                    --instance "${FORGEJO_INSTANCE_URL}" \
                    --token "${RUNNER_TOKEN}" \
                    --name "${RUNNER_NAME}" \
                    --labels "ubuntu-latest:docker://node:20-bookworm,ubuntu-22.04:docker://node:20-bookworm,docker:docker://docker:27-cli" || true
                fi
              fi

              # Ensure .runner is placed in /data/.runner
              if [ -f .runner ] && [ ! -f /data/.runner ]; then
                cp .runner /data/.runner
              elif [ -f /.runner ] && [ ! -f /data/.runner ]; then
                cp /.runner /data/.runner
              fi

              if [ ! -f /data/.runner ]; then
                echo "CRITICAL: /data/.runner still does not exist! Registration failed."
                echo "Listing directory contents:"
                ls -la /data /
                sleep 30
                exit 1
              fi

              echo "Runner registration confirmed in /data/.runner."
              echo "Starting forgejo-runner daemon..."
              exec forgejo-runner daemon --config /etc/forgejo-runner/config.yaml
          env:
            - name: DOCKER_HOST
              value: "tcp://127.0.0.1:2375"
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
            - name: runner-data
              mountPath: /data
            - name: runner-config
              mountPath: /etc/forgejo-runner/config.yaml
              subPath: config.yaml
      volumes:
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

log_step "Purging stale registration state and restarting runner pod..."
kubectl exec -n forgejo-runner statefulset/forgejo-runner -c runner -- rm -f /data/.runner 2>/dev/null || true
kubectl delete pod forgejo-runner-0 -n forgejo-runner --grace-period=0 --force >/dev/null 2>&1 || true

log_info "Waiting for new runner pod to initialize..."
kubectl rollout status statefulset/forgejo-runner -n forgejo-runner --timeout=60s

log_step "Waiting for Runner to complete registration and start daemon..."
REG_SUCCESS=false
for i in $(seq 1 25); do
    LOGS=$(kubectl logs -n forgejo-runner statefulset/forgejo-runner -c runner --tail=30 2>/dev/null || true)
    if echo "$LOGS" | grep -qi -E "(Runner successfully registered|Starting forgejo-runner daemon|daemon is running)"; then
        REG_SUCCESS=true
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

if [ "$REG_SUCCESS" = true ]; then
    echo ""
    echo -e "${GREEN}${BOLD}==============================================================================${NC}"
    echo -e "${GREEN}${BOLD}       ✔ FORGEJO ACTIONS RUNNER SUCCESSFULLY REGISTERED & ONLINE!${NC}"
    echo -e "${GREEN}${BOLD}==============================================================================${NC}"
    echo -e " Runner Name:       ${BOLD}${RUNNER_NAME}${NC}"
    echo -e " Target Namespace:  forgejo-runner"
    echo -e " Docker Transport:  tcp://127.0.0.1:2375"
    echo -e " Registered At:     http://forgejo-http.forgejo.svc.cluster.local:3000"
    echo ""
    echo -e " Verify in your browser:"
    echo -e " 👉 Admin Panel:    https://git.<domain>/admin/actions/runners"
    echo -e "${GREEN}${BOLD}==============================================================================${NC}\n"
else
    log_warn "Current runner container logs:"
    echo "$LOGS"
    echo ""
    log_warn "Current dind container logs:"
    kubectl logs -n forgejo-runner statefulset/forgejo-runner -c dind --tail=20 2>/dev/null || true
fi
