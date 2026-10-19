# DNS & TLS Certificates Guide

This document describes DNS configuration, cert-manager behavior, and switching between self-signed and production Let's Encrypt certificates.

---

## 1. Required DNS Records

Set up the following `A` or `CNAME` records at your DNS registrar pointing to your server's public IP address:

| Hostname | Type | Target |
| :--- | :--- | :--- |
| `git.yourdomain.com` | `A` | `<SERVER_PUBLIC_IP>` |
| `plane.yourdomain.com` | `A` | `<SERVER_PUBLIC_IP>` |
| `itsaplan.yourdomain.com` | `A` | `<SERVER_PUBLIC_IP>` |
| `api.itsaplan.yourdomain.com` | `A` | `<SERVER_PUBLIC_IP>` |

*(Alternatively, create a single wildcard record: `*.yourdomain.com` -> `<SERVER_PUBLIC_IP>`)*

---

## 2. Choosing Your Certificate Issuer

In [inventory/group_vars/all.yml](file:///home/dsv/work/pipeline/inventory/group_vars/all.yml), the `cert_issuer` variable controls which issuer issues your TLS certificates:

### Option A: `selfsigned-issuer` (Default for Testing / Private Domains)
- Generates internal TLS certificates immediately without contacting any external CA.
- Browser will show a certificate warning which you can accept.
- Useful for local IP testing or staging before real domains are configured.

### Option B: `letsencrypt-staging`
- Requests certificates from Let's Encrypt's staging environment.
- Has high rate limits; ideal for verifying that Traefik HTTP-01 challenge routing works properly.

### Option C: `letsencrypt-prod` (Recommended for Production)
- Requests genuine, publicly trusted certificates from Let's Encrypt.
- Requires your DNS records to be fully propagated to the server's public IP on port 80.

---

## 3. Switching to Production Certificates

Once DNS records are verified and pointing to the server IP:

1. Edit [inventory/group_vars/all.yml](file:///home/dsv/work/pipeline/inventory/group_vars/all.yml):
   ```yaml
   cert_issuer: "letsencrypt-prod"
   acme_email: "your-email@yourdomain.com"
   ```

2. Re-run the deployment playbook:
   ```bash
   ./scripts/deploy-cluster.sh --tags forgejo,plane,itsaplan
   ```

3. Check certificate status:
   ```bash
   kubectl get certificates -A
   kubectl describe certificate forgejo-tls -n forgejo
   ```
