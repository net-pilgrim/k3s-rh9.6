# Quickstart Deployment Guide

Deploy your full k3s cluster with Forgejo, CI/CD Runner, Plane, and It's a Plan in 3 simple steps.

---

## Method A: ⚡ The 1-Command Fast Path (`curl | bash`)

If you want immediate installation directly on the target server without managing local Ansible files:

```bash
# Auto-detects public IP and binds working subdomains via nip.io:
curl -fsSL https://gist.githubusercontent.com/net-pilgrim/4f37e7e0d0ddb74b902c526246a76418/raw/install.sh | bash

# Or for custom domains with Let's Encrypt:
DOMAIN="example.com" TLS=letsencrypt EMAIL="admin@example.com" curl -fsSL https://gist.githubusercontent.com/net-pilgrim/4f37e7e0d0ddb74b902c526246a76418/raw/install.sh | bash
```

---

## Method B: Remote Provisioning via Ansible (From Local Workstation)

## Prerequisites

1. A clean Linux server or VPS (Ubuntu 22.04 / 24.04 LTS or Debian 12 recommended) with root or sudo SSH access.
   - Recommended specs: 4+ vCPU, 8+ GB RAM (to comfortably host all microservices & DinD runner).
2. DNS A records pointing to your server IP:
   - `git.<yourdomain.com>`
   - `plane.<yourdomain.com>`
   - `itsaplan.<yourdomain.com>`
   - `api.itsaplan.<yourdomain.com>`
   *(Or wildcard `*.<yourdomain.com>`)*

---

## Step 1: Set Up Local Machine Tools

On your local workstation (where you run the deployment):

```bash
cd /home/dsv/work/pipeline
./scripts/setup-local-tools.sh
```

This installs `ansible-core` and necessary collections for your local user without touching system packages.

---

## Step 2: Configure Inventory & Secrets

1. **Edit the target server IP:**
   Open [inventory/hosts.ini](file:///home/dsv/work/pipeline/inventory/hosts.ini) and replace `YOUR_SERVER_IP` with your remote server IP:
   ```ini
   [server]
   k3s-master ansible_host=203.0.113.10 ansible_user=root
   ```

2. **Configure your domain and credentials:**
   Open [inventory/group_vars/all.yml](file:///home/dsv/work/pipeline/inventory/group_vars/all.yml):
   ```yaml
   base_domain: "yourdomain.com"
   acme_email: "you@yourdomain.com"
   cert_issuer: "letsencrypt-prod" # or keep "selfsigned-issuer" for testing
   ```

---

## Step 3: Run the Deployment

Execute the automated deployer:

```bash
./scripts/deploy-cluster.sh
```

Ansible will:
1. Harden kernel networking parameters and disable swap on the server.
2. Install k3s with Traefik ingress and export the kubeconfig to `~/.kube/k3s-pipeline.yaml`.
3. Install cert-manager with Let's Encrypt cluster issuers.
4. Deploy Forgejo and its Persistent Volumes.
5. Auto-generate the runner registration token and deploy the Forgejo DinD Runner.
6. Deploy Plane (`plane.so`) project management suite.
7. Deploy It's a Plan (`itsaplan.dev`) AI-native issue tracker and run database migrations.

---

## Step 4: Verify Deployment

Run the automated health checker:

```bash
./scripts/health-check.sh
```

You can now open your browser and access:
- **Forgejo**: `https://git.yourdomain.com` (Login: `forgejo-admin`)
- **Plane**: `https://plane.yourdomain.com`
- **It's a Plan**: `https://itsaplan.yourdomain.com`
