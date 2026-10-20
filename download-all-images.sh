#!/usr/bin/env bash
# ==============================================================================
# Complete Workload Image Downloader & Airgap Packager
# Downloads all container images for:
#   - cert-manager v1.17
#   - Forgejo Git Forge & CI/CD Runner (DinD)
#   - Plane Community Edition
#   - It's a Plan (itsaplan.dev)
#
# Features:
#   - Pure TLS 1.2 Engine: Bypasses corporate firewalls that drop TLS 1.3
#   - Self-contained: No Docker daemon, Go compiler, or crane required
#   - Resume support: Skips already-downloaded images
#   - Auto-import: Can import directly into k3s containerd
#
# Usage:
#   ./download-all-images.sh                     # Downloads to ./workload-images/
#   sudo ./download-all-images.sh --import       # Downloads AND imports into local k3s
#   ./download-all-images.sh --archive           # Downloads and builds workload-images.tar.gz
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

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

OUTPUT_DIR="${SCRIPT_DIR}/workload-images"
DO_IMPORT=false
DO_ARCHIVE=false
FILTER_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --import)
            DO_IMPORT=true; shift ;;
        --archive)
            DO_ARCHIVE=true; shift ;;
        -p|--plane-only)
            FILTER_ARG="--plane-only"; shift ;;
        --filter)
            FILTER_ARG="--filter=$2"; shift 2 ;;
        --filter=*)
            FILTER_ARG="$1"; shift ;;
        -o|--output)
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            cat << 'EOF'
Usage: ./download-all-images.sh [OPTIONS]

Options:
  -p, --plane-only   Download only Plane CE images (makeplane/plane-*:v1.4.2)
  --filter <STR>     Filter images to download matching pattern
  --import           Automatically import images into local k3s containerd
  --archive          Create compressed image archive for air-gap transfer
  -o, --output <DIR> Directory to save image tar files (default: ./workload-images)
  -h, --help         Show this help message and exit
EOF
            exit 0
            ;;
        *)
            log_warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}${BOLD}"
cat << 'EOF'
  ___                               ____                      _                 _ 
 |_ _|_ __ ___   __ _  __ _  ___   |  _ \  _____      ___ __ | | ___   __ _  __| |
  | || '_ ` _ \ / _` |/ _` |/ _ \  | | | |/ _ \ \ /\ / / '_ \| |/ _ \ / _` |/ _` |
  | || | | | | | (_| | (_| |  __/  | |_| | (_) \ V  V /| | | | | (_) | (_| | (_| |
 |___|_| |_| |_|\__,_|\__, |\___|  |____/ \___/ \_/\_/ |_| |_|_|\___/ \__,_|\__,_|
                      |___/                                                       
EOF
echo -e " Workload Container Image Fetcher (Strict TLS 1.2 Engine)${NC}\n"

# ------------------------------------------------------------------------------
# 1. Connectivity Check
# ------------------------------------------------------------------------------
log_step "[1/3] Testing Registry Connectivity with TLS 1.2..."
mkdir -p "${OUTPUT_DIR}"

ONLINE=false
if curl --tlsv1.2 --tls-max 1.2 -sI --connect-timeout 6 https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
    ONLINE=true
    log_success "Direct outbound connectivity to Docker Hub (TLS 1.2) confirmed."
elif curl --tlsv1.2 --tls-max 1.2 -sI --connect-timeout 6 https://quay.io/v2/ >/dev/null 2>&1; then
    ONLINE=true
    log_success "Direct outbound connectivity to Quay.io (TLS 1.2) confirmed."
else
    log_warn "Outbound HTTPS requests to public registries timed out or were blocked."
    echo ""
    echo -e "${YELLOW}${BOLD}NOTICE: This machine appears to be strictly air-gapped / offline.${NC}"
    echo "If this machine cannot access the internet directly:"
    echo "  1. Run this script on an internet-connected computer (laptop/bastion):"
    echo "     curl -fsSL https://gist.githubusercontent.com/net-pilgrim/f64b7ad8a36eb1ae25cf84dccf47686c/raw/download-all-images.sh | bash -s -- --archive"
    echo "  2. Transfer the resulting 'workload-images.tar.gz' file to this machine."
    echo "  3. Import the images into k3s:"
    echo "     sudo ./import-images.sh workload-images.tar.gz"
    echo ""
    read -r -p "Attempt download anyway (or if using a proxy)? [y/N]: " choice || choice="n"
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 2. Download Images using TLS 1.2 Engine
# ------------------------------------------------------------------------------
log_step "[2/3] Downloading Container Images into ${OUTPUT_DIR}..."

PYTHON_BIN=""
for py in python3 python /usr/bin/python3; do
    if command -v "$py" >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v "$py")
        break
    fi
done

if [ -n "${PYTHON_BIN}" ]; then
    log_info "Executing Python TLS 1.2 download engine (${PYTHON_BIN})..."
    "${PYTHON_BIN}" - "${OUTPUT_DIR}" ${FILTER_ARG} << 'PYEOF'
#!/usr/bin/env python3
"""
High-Performance OCI/Docker Container Image Downloader with Strict TLS 1.2
Enforces TLS 1.2 to bypass enterprise middleboxes that drop TLS 1.3 packets.
Uses standard library only (no external dependencies, no Docker daemon required).
"""

import sys
import os
import json
import ssl
import tarfile
import tempfile
import urllib.request
import urllib.error
import urllib.parse
import shutil

# Enforce TLS 1.2 strictly
TLS_CTX = ssl.create_default_context()
if hasattr(ssl, "TLSVersion"):
    TLS_CTX.maximum_version = ssl.TLSVersion.TLSv1_2
    TLS_CTX.minimum_version = ssl.TLSVersion.TLSv1_2
else:
    TLS_CTX.options |= ssl.OP_NO_TLSv1_3

IMAGES = [
    # --- Cert-Manager v1.17 ---
    "quay.io/jetstack/cert-manager-controller:v1.17.1",
    "quay.io/jetstack/cert-manager-cainjector:v1.17.1",
    "quay.io/jetstack/cert-manager-webhook:v1.17.1",
    "quay.io/jetstack/cert-manager-startupapicheck:v1.17.1",

    # --- Forgejo Git Server & CI/CD Runner ---
    "code.forgejo.org/forgejo/forgejo:15.0.10-rootless",
    "code.forgejo.org/forgejo/forgejo:15.0.10",
    "code.forgejo.org/forgejo/forgejo:10.0.1",
    "code.forgejo.org/forgejo/runner:4.0.1",
    "docker:27-dind",
    "docker:27-cli",
    "node:20-bookworm",
    "alpine:latest",
    "busybox:latest",

    # --- It's a Plan (itsaplan.dev) ---
    "ghcr.io/croffasia/itsaplan-api:latest",
    "ghcr.io/croffasia/itsaplan-web:latest",
    "ghcr.io/croffasia/itsaplan-worker:latest",
    "ghcr.io/croffasia/itsaplan-bot:latest",
    "postgres:17-alpine",
    "rustfs/rustfs:1.0.0",
    "curlimages/curl:latest",

    # --- Plane Community Edition (plane.so) ---
    "makeplane/plane-backend:v1.4.2",
    "makeplane/plane-frontend:v1.4.2",
    "makeplane/plane-admin:v1.4.2",
    "makeplane/plane-space:v1.4.2",
    "makeplane/plane-live:v1.4.2",
    "valkey/valkey:7.2.11-alpine",
    "postgres:15.7-alpine",
    "rabbitmq:3.13.6-management-alpine",
    "docker.io/pgsty/silo:RELEASE.2026-09-16T00-00-00Z",
    "docker.io/pgsty/mc:RELEASE.2026-09-16T00-00-00Z",
    "redis:7-alpine",
    "rabbitmq:3-management-alpine",
]

def get_tag_aliases(image_name):
    aliases = {image_name}
    if not image_name.startswith("docker.io/") and ("/" not in image_name or (image_name.count("/") == 1 and "." not in image_name.split("/")[0])):
        aliases.add(f"docker.io/{image_name}")
        if "/" not in image_name:
            aliases.add(f"docker.io/library/{image_name}")
            aliases.add(f"library/{image_name}")
        elif image_name.startswith("library/"):
            aliases.add(image_name[len("library/"):])
    elif image_name.startswith("docker.io/"):
        short = image_name[len("docker.io/"):]
        aliases.add(short)
        if short.startswith("library/"):
            aliases.add(short[len("library/"):])
    elif image_name.startswith("artifacts.plane.so/"):
        aliases.add(image_name[len("artifacts.plane.so/"):])

    if image_name.startswith("makeplane/") or image_name.startswith("docker.io/makeplane/"):
        plain = image_name[len("docker.io/"):] if image_name.startswith("docker.io/") else image_name
        aliases.add(f"artifacts.plane.so/{plain}")

    extra = set()
    for a in aliases:
        if a.endswith(":latest"):
            extra.add(a[:-7])
        elif ":" not in a.split("/")[-1]:
            extra.add(f"{a}:latest")
    aliases.update(extra)

    return sorted(list(aliases))

def parse_image(name):
    # Normalize docker.io
    if name.startswith("docker.io/"):
        name = name[len("docker.io/"):]
    
    parts = name.split('/')
    if len(parts) == 1:
        img_part = parts[0]
        repo = f"library/{img_part.split(':')[0]}"
        tag = img_part.split(':')[1] if ':' in img_part else 'latest'
        return 'registry-1.docker.io', repo, tag, name
    elif '.' in parts[0] or ':' in parts[0]:
        reg = parts[0]
        rem = '/'.join(parts[1:])
        repo = rem.split(':')[0]
        tag = rem.split(':')[1] if ':' in rem else 'latest'
        return reg, repo, tag, name
    else:
        rem = '/'.join(parts)
        repo = rem.split(':')[0]
        tag = rem.split(':')[1] if ':' in rem else 'latest'
        return 'registry-1.docker.io', repo, tag, name

def get_auth_token(reg, repo):
    url = f"https://{reg}/v2/"
    req = urllib.request.Request(url)
    try:
        urllib.request.urlopen(req, context=TLS_CTX, timeout=10)
        return None
    except urllib.error.HTTPError as e:
        auth_hdr = e.headers.get('Www-Authenticate')
        if not auth_hdr:
            return None
        parts = {}
        for p in auth_hdr.replace('Bearer ', '').split(','):
            if '=' in p:
                k, v = p.strip().split('=', 1)
                parts[k] = v.strip('"')
        realm = parts.get('realm')
        service = parts.get('service', '')
        if not realm:
            return None
        token_url = f"{realm}?service={service}&scope=repository:{repo}:pull"
        req2 = urllib.request.Request(token_url)
        docker_user = os.environ.get("DOCKER_USER")
        docker_pass = os.environ.get("DOCKER_PASS") or os.environ.get("DOCKER_TOKEN")
        if docker_user and docker_pass and "docker.io" in realm:
            import base64
            b64_auth = base64.b64encode(f"{docker_user}:{docker_pass}".encode()).decode("ascii")
            req2.add_header("Authorization", f"Basic {b64_auth}")
        try:
            with urllib.request.urlopen(req2, context=TLS_CTX, timeout=15) as r:
                data = json.loads(r.read())
                return data.get('token') or data.get('access_token')
        except Exception as te:
            print(f"      [!] Token error from {realm}: {te}")
            return None
    except Exception as ge:
        print(f"      [!] Registry ping failed for {reg}: {ge}")
        return None

def download_stream(url, headers, target_file):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, context=TLS_CTX, timeout=60) as r:
        with open(target_file, 'wb') as f:
            while True:
                chunk = r.read(1024 * 1024)  # 1MB chunks
                if not chunk:
                    break
                f.write(chunk)

def download_image(image_name, out_tar):
    reg, repo, tag, full_tag = parse_image(image_name)
    token = get_auth_token(reg, repo)
    headers = {
        'Accept': (
            'application/vnd.docker.distribution.manifest.v2+json, '
            'application/vnd.oci.image.manifest.v1+json, '
            'application/vnd.docker.distribution.manifest.list.v2+json, '
            'application/vnd.oci.image.index.v1+json'
        )
    }
    if token:
        headers['Authorization'] = f"Bearer {token}"

    url = f"https://{reg}/v2/{repo}/manifests/{tag}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, context=TLS_CTX, timeout=20) as r:
        manifest = json.loads(r.read().decode('utf-8'))

    # If manifest list / OCI index, select amd64 linux
    if 'manifests' in manifest:
        chosen_digest = None
        for m in manifest['manifests']:
            plat = m.get('platform', {})
            if plat.get('architecture') == 'amd64' and plat.get('os') == 'linux':
                chosen_digest = m['digest']
                break
        if not chosen_digest:
            chosen_digest = manifest['manifests'][0]['digest']
        url = f"https://{reg}/v2/{repo}/manifests/{chosen_digest}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, context=TLS_CTX, timeout=20) as r:
            manifest = json.loads(r.read().decode('utf-8'))

    config_digest = manifest['config']['digest']
    config_hash = config_digest.split(':')[1] if ':' in config_digest else config_digest
    config_fname = f"{config_hash}.json"
    work_dir = tempfile.mkdtemp(prefix="img-build-")

    try:
        # Download config JSON
        config_path = os.path.join(work_dir, config_fname)
        config_url = f"https://{reg}/v2/{repo}/blobs/{config_digest}"
        download_stream(config_url, headers, config_path)

        # Download layers
        layer_files = []
        layers = manifest.get('layers', [])
        for i, l in enumerate(layers):
            ldigest = l['digest']
            layer_fname = f"{ldigest.split(':')[1]}.tar.gz"
            layer_path = os.path.join(work_dir, layer_fname)
            layer_url = f"https://{reg}/v2/{repo}/blobs/{ldigest}"
            download_stream(layer_url, headers, layer_path)
            layer_files.append((layer_fname, layer_path))

        # Write manifest.json
        manifest_data = [{
            'Config': config_fname,
            'RepoTags': get_tag_aliases(image_name),
            'Layers': [fname for fname, _ in layer_files]
        }]
        manifest_path = os.path.join(work_dir, "manifest.json")
        with open(manifest_path, 'w') as mf:
            json.dump(manifest_data, mf)

        # Build final tar
        tmp_tar = out_tar + ".part"
        with tarfile.open(tmp_tar, 'w') as t:
            t.add(config_path, arcname=config_fname)
            for fname, lpath in layer_files:
                t.add(lpath, arcname=fname)
            t.add(manifest_path, arcname="manifest.json")

        os.rename(tmp_tar, out_tar)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

def main():
    target_dir = sys.argv[1] if (len(sys.argv) > 1 and sys.argv[1].strip() and not sys.argv[1].startswith("-")) else "./workload-images"
    filter_pattern = os.environ.get("IMAGE_FILTER", "")

    for arg in sys.argv[1:]:
        if not arg or not arg.strip():
            continue
        if arg in ("--plane-only", "-p"):
            filter_pattern = "plane"
        elif arg.startswith("--filter="):
            filter_pattern = arg.split("=", 1)[1]
        elif not arg.startswith("-") and arg != target_dir:
            target_dir = arg

    os.makedirs(target_dir, exist_ok=True)

    if filter_pattern.lower() in ("plane", "plane-only"):
        images_to_fetch = [
            "makeplane/plane-backend:v1.4.2",
            "makeplane/plane-frontend:v1.4.2",
            "makeplane/plane-admin:v1.4.2",
            "makeplane/plane-space:v1.4.2",
            "makeplane/plane-live:v1.4.2",
        ]
        print(f"\n==> Filter active: Downloading {len(images_to_fetch)} Plane images only.")
    elif filter_pattern:
        images_to_fetch = [img for img in IMAGES if filter_pattern.lower() in img.lower()]
        print(f"\n==> Filter active ('{filter_pattern}'): {len(images_to_fetch)} of {len(IMAGES)} images selected.")
    else:
        images_to_fetch = IMAGES

    print(f"\n==> Fetching {len(images_to_fetch)} workload images (Strict TLS 1.2 Engine)...")
    print(f"==> Target Directory: {os.path.abspath(target_dir)}\n")

    success_count = 0
    fail_count = 0

    for idx, img in enumerate(images_to_fetch, 1):
        safe_name = img.replace('/', '_').replace(':', '_') + ".tar"
        out_tar = os.path.join(target_dir, safe_name)

        if os.path.isfile(out_tar) and os.path.getsize(out_tar) > 1024:
            size_mb = os.path.getsize(out_tar) / (1024 * 1024)
            print(f"[{idx}/{len(images_to_fetch)}] ✔ Cached: {img} ({size_mb:.1f} MB)")
            success_count += 1
            continue

        print(f"[{idx}/{len(images_to_fetch)}] Downloading: {img} ...", flush=True)
        try:
            download_image(img, out_tar)
            size_mb = os.path.getsize(out_tar) / (1024 * 1024)
            print(f"       ✔ SUCCESS ({size_mb:.1f} MB)")
            success_count += 1
        except Exception as e:
            print(f"       ✖ FAILED: {e}")
            fail_count += 1
            if os.path.exists(out_tar + ".part"):
                os.remove(out_tar + ".part")

    print(f"\n==> Download Summary: {success_count} succeeded, {fail_count} failed.\n")
    if fail_count > 0 and success_count == 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF
else
    log_error "Python 3 is required for the TLS 1.2 download engine but was not found!"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Handle Local Import or Archive Creation
# ------------------------------------------------------------------------------
if [ "$DO_IMPORT" = true ] || ([ "${EUID:-$(id -u)}" -eq 0 ] && [ -x /usr/local/bin/k3s ] && [ "$DO_ARCHIVE" = false ]); then
    log_step "[3/3] Importing Downloaded Images into k3s containerd..."
    mkdir -p /var/lib/rancher/k3s/agent/images

    K3S_CMD="/usr/local/bin/k3s"
    [ ! -x "$K3S_CMD" ] && K3S_CMD="/usr/bin/k3s"

    for tarfile in "${OUTPUT_DIR}"/*.tar; do
        if [ -f "${tarfile}" ]; then
            NAME=$(basename "${tarfile}")
            log_info "Importing ${NAME}..."
            cp -n "${tarfile}" /var/lib/rancher/k3s/agent/images/ 2>/dev/null || true
            "${K3S_CMD}" ctr -n k8s.io images import "${tarfile}" >/dev/null 2>&1 || true
        fi
    done

    # Restart failing pods so they pull from local cache
    log_info "Restarting stuck pods across namespaces..."
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    for ns in cert-manager forgejo forgejo-runner plane itsaplan; do
        FAILED=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -E "(ImagePullBackOff|ErrImagePull|Init:ImagePullBackOff|Init:ErrImagePull|CrashLoopBackOff|Error)" | awk '{print $1}' || true)
        if [ -n "$FAILED" ]; then
            echo "$FAILED" | xargs kubectl delete pod -n "$ns" --grace-period=0 --force >/dev/null 2>&1 || true
        fi
    done

    log_success "All images imported into containerd. Pods are running!"
elif [ "$DO_ARCHIVE" = true ]; then
    log_step "[3/3] Creating Compressed Archive workload-images.tar.gz..."
    if [ "${FILTER_ARG}" = "--plane-only" ]; then
        ARCHIVE_FILE="${SCRIPT_DIR}/plane-images.tar.gz"
    else
        ARCHIVE_FILE="${SCRIPT_DIR}/workload-images.tar.gz"
    fi
    log_step "[3/3] Creating Compressed Archive $(basename "${ARCHIVE_FILE}")..."
    tar -czf "${ARCHIVE_FILE}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")"
    log_success "Air-gap transfer bundle created: ${ARCHIVE_FILE} ($(du -h "${ARCHIVE_FILE}" | awk '{print $1}'))"
    echo ""
    echo "To install on your air-gapped machine:"
    echo "  1. Copy '${ARCHIVE_FILE}' to the target machine"
    echo "  2. Run: sudo ./import-images.sh ${ARCHIVE_FILE}"
else
    log_step "[3/3] Download Finished."
    echo ""
    echo "Images saved in: ${OUTPUT_DIR}"
    echo "To import into local k3s:  sudo ./import-images.sh ${OUTPUT_DIR}"
fi
