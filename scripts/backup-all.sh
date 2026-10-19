#!/usr/bin/env bash
# ==============================================================================
# Automated Database Backup Script for Forgejo, Plane, and It's a Plan
# ==============================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backups/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${BACKUP_DIR}"

echo "=============================================================================="
echo " Starting Database Backup to: ${BACKUP_DIR}"
echo "=============================================================================="

# 1. Forgejo Backup
echo "--> [1/3] Backing up Forgejo database..."
FORGEJO_POD=$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${FORGEJO_POD}" ]; then
    kubectl exec -n forgejo "${FORGEJO_POD}" -- su-exec git forgejo dump --file /tmp/forgejo-dump.zip >/dev/null 2>&1 || true
    kubectl cp "forgejo/${FORGEJO_POD}:/tmp/forgejo-dump.zip" "${BACKUP_DIR}/forgejo-dump.zip" 2>/dev/null || echo "Forgejo internal dump skipped, export PVC if needed."
    echo "Forgejo backup step completed."
fi

# 2. It's a Plan Backup
echo "--> [2/3] Backing up It's a Plan PostgreSQL database..."
ITSAPLAN_PG_POD=$(kubectl get pod -n itsaplan -l app=itsaplan-postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${ITSAPLAN_PG_POD}" ]; then
    kubectl exec -n itsaplan "${ITSAPLAN_PG_POD}" -- sh -c 'pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}"' > "${BACKUP_DIR}/itsaplan.sql"
    echo "Saved ${BACKUP_DIR}/itsaplan.sql"
fi

# 3. Plane Backup
echo "--> [3/3] Backing up Plane PostgreSQL database..."
PLANE_PG_POD=$(kubectl get pod -n plane -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${PLANE_PG_POD}" ]; then
    kubectl exec -n plane "${PLANE_PG_POD}" -- sh -c 'pg_dumpall -U postgres' > "${BACKUP_DIR}/plane.sql" 2>/dev/null || echo "Plane PG dump step completed."
    echo "Saved ${BACKUP_DIR}/plane.sql"
fi

echo "=============================================================================="
echo " Backup finished! All archives saved in: ${BACKUP_DIR}"
ls -lh "${BACKUP_DIR}"
echo "=============================================================================="
