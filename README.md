# k3s DevOps & Platform Engineering Stack

A complete, production-ready Infrastructure as Code (IaC) and GitOps deployment for a **k3s Kubernetes cluster** hosting:
1. **Forgejo**: Self-hosted Git forge (Gitea fork) with native Actions support.
2. **Forgejo DinD Runner**: High-performance CI/CD runner with an isolated Docker-in-Docker sidecar.
3. **Plane (`plane.so`)**: Open-source, extensible project management platform (Linear/Jira alternative).
4. **It's a Plan (`itsaplan.dev`)**: AI-first issue tracker and project management platform built for human-AI agent collaboration.

---

## Architecture Overview

```
                                  +-----------------------+
                                  |   Internet / Clients  |
                                  +-----------------------+
                                              |
                                     HTTPS 443 / SSH 32222
                                              v
+-----------------------------------------------------------------------------------------------+
| k3s Server Node                                                                               |
|                                                                                               |
|  [Traefik Ingress Controller] <----+ cert-manager (Let's Encrypt / ACME HTTP-01)              |
|        |                  |                    |                    |                         |
|        v                  v                    v                    v                         |
|  +------------+   +---------------+     +--------------+     +----------------+               |
|  |  Forgejo   |   | Forgejo DinD  |     |   Plane.so   |     |  It's a Plan   |               |
|  | Git Server |   | CI/CD Runner  |     | (Management) |     |  (AI-Native)   |               |
|  +------------+   +---------------+     +--------------+     +----------------+               |
|  | - Web / UI |   | - act_runner  |     | - Frontend   |     | - Web (3001)   |               |
|  | - Git SSH  |   | - dind daemon |     | - API        |     | - API (3000)   |               |
|  | - Actions  |   | - 20GB cache  |     | - Postgres   |     | - Postgres 17  |               |
|  | - Postgres |   | - Auto-token  |     | - Redis      |     | - RustFS (S3)  |               |
|  | - PVC 20GB |   | - PVC 5GB     |     | - MinIO/RMQ  |     | - Worker / Bot |               |
|  +------------+   +---------------+     +--------------+     +----------------+               |
|                                                                                               |
|  [Storage Engine: k3s local-path-provisioner (/var/lib/rancher/k3s/storage)]                  |
+-----------------------------------------------------------------------------------------------+
```

---

## ⚡ One-Liner Self-Installing Script (`curl | bash`)

You can run the all-in-one installer directly on any fresh **RHEL 9.6 / 9.x**, Rocky Linux, AlmaLinux, Ubuntu, or Debian server:

### Option A: Dynamic Auto-DNS (`nip.io`) — Zero Setup Required
If you do not have a domain configured yet, simply run:
```bash
curl -fsSL https://gist.githubusercontent.com/net-pilgrim/4f37e7e0d0ddb74b902c526246a76418/raw/install.sh | bash
```

> [!TIP]
> The script auto-detects your server's public IP and binds all services to `<PUBLIC_IP>.nip.io` (e.g. `git.<PUBLIC_IP>.nip.io`, `plane.<PUBLIC_IP>.nip.io`, `itsaplan.<PUBLIC_IP>.nip.io`) with working HTTPS immediately.

### Option B: Custom Domain with Automated Let's Encrypt TLS
Point your DNS A records (`git.<domain>`, `plane.<domain>`, `itsaplan.<domain>`, `api.itsaplan.<domain>`) to your server IP, then run:
```bash
DOMAIN="yourdomain.com" TLS=letsencrypt EMAIL="admin@yourdomain.com" curl -fsSL https://gist.githubusercontent.com/net-pilgrim/4f37e7e0d0ddb74b902c526246a76418/raw/install.sh | bash
```
Or pass CLI arguments:
```bash
curl -fsSL https://gist.githubusercontent.com/net-pilgrim/4f37e7e0d0ddb74b902c526246a76418/raw/install.sh | bash -s -- --domain yourdomain.com --email admin@yourdomain.com --tls letsencrypt
```

### Option C: 🔒 Air-Gapped / Offline RHEL 9.6 Installation (Zero Internet Access)
If your target machine has no direct internet egress or blocked external repositories:

1. **Build the offline bundle** on any machine with internet:
   ```bash
   ./scripts/build-airgap-bundle.sh
   # Produces: k3s-airgap-rhel9-bundle.tar.gz (k3s binary, k3s-selinux RPM, Helm, airgap images)
   ```
2. **Transfer and extract** on the air-gapped server:
   ```bash
   tar -xzf k3s-airgap-rhel9-bundle.tar.gz
   cd k3s-airgap-rhel9-bundle
   sudo ./install-airgap.sh
   ```

### 🌐 Behind a Corporate Proxy?
If your server requires an HTTP/HTTPS proxy to reach the outside world:
```bash
export http_proxy="http://proxy.corp.internal:8080"
export https_proxy="http://proxy.corp.internal:8080"
export no_proxy="localhost,127.0.0.1,10.42.0.0/16,10.43.0.0/16,cluster.local"
curl -fsSL https://gist.githubusercontent.com/net-pilgrim/4f37e7e0d0ddb74b902c526246a76418/raw/install.sh | bash
```

---

## Directory Structure

```
pipeline/
├── ansible.cfg                          # Ansible configuration (pipelining, SSH settings)
├── site.yml                             # Master orchestration playbook
├── inventory/
│   ├── hosts.ini                        # Target server IP and SSH credentials
│   └── group_vars/
│       └── all.yml                      # Centralized configuration (domains, credentials, TLS)
├── roles/
│   ├── common/                          # Kernel modules, sysctl, swapoff, prerequisites, Helm
│   ├── k3s_server/                      # k3s server bootstrap, kubeconfig extraction
│   ├── k3s_agent/                       # Worker node join logic (optional multi-node)
│   ├── cert_manager/                    # cert-manager v1.17 + Let's Encrypt cluster issuers
│   ├── forgejo/                         # Official Forgejo OCI Helm deployment + Ingress
│   ├── forgejo_runner/                  # Forgejo runner StatefulSet with DinD sidecar
│   ├── plane/                           # Plane.so Helm deployment + microservices
│   └── itsaplan/                        # It's a Plan deployment, DB migrations & Ingress
├── manifests/                            # Pure Kubernetes manifests for manual / direct kubectl apply
│   ├── 00-namespaces.yaml               # Cluster namespaces
│   ├── cert-manager/                    # ClusterIssuers (staging, prod, selfsigned)
│   ├── forgejo/                         # Standalone Helm values for Forgejo
│   ├── forgejo-runner/                  # Runner ConfigMap and StatefulSet manifests
│   ├── plane/                           # Standalone Helm values for Plane
│   └── itsaplan/                        # Declarative manifests & Kustomize for It's a Plan
├── scripts/
│   ├── setup-local-tools.sh             # Local installer for ansible-core & galaxy collections
│   ├── deploy-cluster.sh                # Main automated cluster deployer
│   ├── register-forgejo-runner.sh       # Auto-token generator & runner re-registration
│   ├── health-check.sh                  # Comprehensive cluster health & ingress verification
│   ├── test-e2e-workflow.sh             # Sample CI/CD pipeline push test
│   └── backup-all.sh                    # Automated multi-service PostgreSQL backup script
└── docs/
    ├── QUICKSTART.md                    # Step-by-step setup guide
    ├── ARCHITECTURE.md                  # Network flow, storage, and security model
    ├── FORGEJO_AND_RUNNER.md            # CI/CD runners, DinD, and workflow examples
    ├── PLANE_AND_ITSAPLAN.md            # Plane.so and It's a Plan configuration
    ├── DNS_AND_TLS.md                   # DNS records and Let's Encrypt configuration
    └── OPERATIONS_AND_BACKUPS.md        # Maintenance, logs, and disaster recovery
```

---

## Quick Start (Deploy in 3 Steps)

### 1. Set Up Local Automation Environment
Install `ansible-core` and necessary collections on your local machine:
```bash
./scripts/setup-local-tools.sh
```

### 2. Configure Your Server & Domain
1. Edit [inventory/hosts.ini](file:///home/dsv/work/pipeline/inventory/hosts.ini) with your server's public IP:
   ```ini
   [server]
   k3s-master ansible_host=YOUR_SERVER_IP ansible_user=root
   ```
2. Edit [inventory/group_vars/all.yml](file:///home/dsv/work/pipeline/inventory/group_vars/all.yml) to define your base domain and administrative passwords:
   ```yaml
   base_domain: "yourdomain.com"
   acme_email: "admin@yourdomain.com"
   cert_issuer: "selfsigned-issuer" # switch to "letsencrypt-prod" once DNS is live
   ```

### 3. Deploy
Launch the automated deployment:
```bash
./scripts/deploy-cluster.sh
```

---

## Validating the Cluster

After deployment completes:
```bash
# Run comprehensive health inspection
./scripts/health-check.sh

# Run end-to-end CI/CD Actions test
./scripts/test-e2e-workflow.sh
```

Access your endpoints:
- **Forgejo (Git & Actions)**: `https://git.<yourdomain.com>`
- **Plane (Project Management)**: `https://plane.<yourdomain.com>`
- **It's a Plan (AI-Native Tracker)**: `https://itsaplan.<yourdomain.com>`
- **It's a Plan API**: `https://api.itsaplan.<yourdomain.com>`

---

## Detailed Documentation
- [Quickstart Guide](file:///home/dsv/work/pipeline/docs/QUICKSTART.md)
- [Architecture & Topology](file:///home/dsv/work/pipeline/docs/ARCHITECTURE.md)
- [Forgejo & Runner Operations](file:///home/dsv/work/pipeline/docs/FORGEJO_AND_RUNNER.md)
- [Plane & It's a Plan Guide](file:///home/dsv/work/pipeline/docs/PLANE_AND_ITSAPLAN.md)
- [DNS & Let's Encrypt TLS](file:///home/dsv/work/pipeline/docs/DNS_AND_TLS.md)
- [Operations & Backups](file:///home/dsv/work/pipeline/docs/OPERATIONS_AND_BACKUPS.md)
