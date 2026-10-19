#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Auto-Discover or Re-Register Forgejo Runner
# ==============================================================================
set -euo pipefail

FORGEJO_NS="${FORGEJO_NS:-forgejo}"
RUNNER_NS="${RUNNER_NS:-forgejo-runner}"
RUNNER_STATEFULSET="${RUNNER_STATEFULSET:-forgejo-runner}"

echo "==> Finding active Forgejo pod in namespace '${FORGEJO_NS}'..."
FORGEJO_POD=$(kubectl get pod -n "${FORGEJO_NS}" -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${FORGEJO_POD}" ]; then
    echo "ERROR: Could not find any running Forgejo pod in namespace '${FORGEJO_NS}'."
    exit 1
fi

echo "Found Forgejo pod: ${FORGEJO_POD}"

echo "==> Generating global Actions runner registration token..."
RUNNER_TOKEN=$(kubectl exec -n "${FORGEJO_NS}" "${FORGEJO_POD}" -- forgejo forgejo-cli actions generate-runner-token 2>/dev/null || \
              kubectl exec -n "${FORGEJO_NS}" "${FORGEJO_POD}" -- forgejo actions generate-runner-token 2>/dev/null || \
              kubectl exec -n "${FORGEJO_NS}" "${FORGEJO_POD}" -- gitea actions generate-runner-token 2>/dev/null || true)

if [ -z "${RUNNER_TOKEN}" ]; then
    echo "ERROR: Failed to generate token automatically from the pod."
    echo "Please generate a runner token manually in Forgejo UI -> Site Administration -> Actions -> Runners -> Create new Runner,"
    echo "and pass it as: ./scripts/register-forgejo-runner.sh <TOKEN>"
    if [ $# -ge 1 ]; then
        RUNNER_TOKEN="$1"
        echo "Using token passed via argument."
    else
        exit 1
    fi
fi

echo "Successfully acquired token: ${RUNNER_TOKEN:0:6}********"

echo "==> Updating Kubernetes Secret 'forgejo-runner-secret' in namespace '${RUNNER_NS}'..."
kubectl create secret generic forgejo-runner-secret \
    --namespace "${RUNNER_NS}" \
    --from-literal=token="${RUNNER_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "==> Restarting runner StatefulSet to trigger registration..."
kubectl rollout restart statefulset "${RUNNER_STATEFULSET}" -n "${RUNNER_NS}"
kubectl rollout status statefulset "${RUNNER_STATEFULSET}" -n "${RUNNER_NS}" --timeout=120s

echo "==> Runner logs:"
kubectl logs -n "${RUNNER_NS}" "${RUNNER_STATEFULSET}-0" -c runner --tail=20
echo "=============================================================================="
echo " Forgejo Runner successfully registered and running!"
echo "=============================================================================="
