#!/usr/bin/env bash
# ==============================================================================
# Health Check & Inspection Script for k3s Platform
# ==============================================================================
set -euo pipefail

# Use cluster kubeconfig if present
KUBECONFIG_CANDIDATE="${HOME}/.kube/k3s-pipeline.yaml"
if [ -f "${KUBECONFIG_CANDIDATE}" ]; then
    export KUBECONFIG="${KUBECONFIG_CANDIDATE}"
fi

echo "=============================================================================="
echo "                k3s Platform Health Check"
echo "=============================================================================="

echo "--> [1/5] Kubernetes Nodes Status:"
kubectl get nodes -o wide

echo ""
echo "--> [2/5] Platform Pods Status across Namespaces:"
kubectl get pods -A -l 'app.kubernetes.io/name in (forgejo),app in (forgejo-runner,itsaplan-postgres,itsaplan-minio,itsaplan-api,itsaplan-worker,itsaplan-bot,itsaplan-web,plane-api,plane-frontend)' -o wide 2>/dev/null || \
kubectl get pods -A

echo ""
echo "--> [3/5] Persistent Volume Claims:"
kubectl get pvc -A

echo ""
echo "--> [4/5] Ingress Routes & Endpoints:"
kubectl get ingress -A

echo ""
echo "--> [5/5] TLS Certificates & Issuers:"
if kubectl get clusterissuers >/dev/null 2>&1; then
    echo "ClusterIssuers:"
    kubectl get clusterissuers
    echo ""
    echo "Certificates:"
    kubectl get certificates -A 2>/dev/null || echo "No certificates requested yet."
fi

echo "=============================================================================="
echo " Health check complete!"
echo "=============================================================================="
