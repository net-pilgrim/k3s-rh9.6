# Operations, Monitoring & Backups Guide

This guide details day-to-day operations, log inspection, troubleshooting, and automated database backups.

---

## 1. Useful Operational Commands

### Checking Cluster Pods & Status:
```bash
# Using the bundled helper script:
./scripts/health-check.sh

# Or directly with kubectl:
kubectl get pods -A -o wide
```

### Inspecting Service Logs:
```bash
# Forgejo logs
kubectl logs -n forgejo -l app.kubernetes.io/name=forgejo -f

# Forgejo Runner daemon logs
kubectl logs -n forgejo-runner statefulset/forgejo-runner -c runner -f

# Docker-in-Docker daemon logs
kubectl logs -n forgejo-runner statefulset/forgejo-runner -c dind -f

# Plane API backend logs
kubectl logs -n plane -l app.kubernetes.io/name=plane-api -f

# It's a Plan API backend logs
kubectl logs -n itsaplan -l app=itsaplan-api -f

# It's a Plan Worker logs
kubectl logs -n itsaplan -l app=itsaplan-worker -f
```

---

## 2. Automated Backups

To execute a full backup of all PostgreSQL databases (Forgejo, Plane, and It's a Plan):

```bash
./scripts/backup-all.sh
```

Backups are exported into `./backups/<YYYYMMDD_HHMMSS>/`:
- `forgejo-dump.zip`: Git repositories, issues, wiki, avatars, and database dump.
- `plane.sql`: Complete PostgreSQL dump of Plane workspaces, issues, and metadata.
- `itsaplan.sql`: Complete PostgreSQL 17 dump of It's a Plan database.

### Setting up a Nightly Backup Cron Job:
Add to the server's crontab (`crontab -e`):
```cron
0 2 * * * cd /path/to/pipeline && ./scripts/backup-all.sh >> /var/log/pipeline-backup.log 2>&1
```

---

## 3. Storage & Node Maintenance

If disk space needs cleanup:
```bash
# Clean unused Docker images inside the DinD runner
kubectl exec -n forgejo-runner statefulset/forgejo-runner -c dind -- docker system prune -af --volumes

# Inspect host PVC storage usage
df -h /var/lib/rancher/k3s/storage/
```
