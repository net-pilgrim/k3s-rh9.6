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
    "minio/minio:RELEASE.2023-09-07T02-17-04Z"
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
    work_dir = tempfile.mkdtemp(prefix="img-build-")

    try:
        # Download config JSON
        config_path = os.path.join(work_dir, config_digest)
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
            'Config': config_digest,
            'RepoTags': get_tag_aliases(image_name),
            'Layers': [fname for fname, _ in layer_files]
        }]
        manifest_path = os.path.join(work_dir, "manifest.json")
        with open(manifest_path, 'w') as mf:
            json.dump(manifest_data, mf)

        # Build final tar
        tmp_tar = out_tar + ".part"
        with tarfile.open(tmp_tar, 'w') as t:
            t.add(config_path, arcname=config_digest)
            for fname, lpath in layer_files:
                t.add(lpath, arcname=fname)
            t.add(manifest_path, arcname="manifest.json")

        os.rename(tmp_tar, out_tar)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

def main():
    target_dir = sys.argv[1] if len(sys.argv) > 1 else "./workload-images"
    os.makedirs(target_dir, exist_ok=True)

    print(f"\n==> Fetching {len(IMAGES)} workload images (Strict TLS 1.2 Engine)...")
    print(f"==> Target Directory: {os.path.abspath(target_dir)}\n")

    success_count = 0
    fail_count = 0

    for idx, img in enumerate(IMAGES, 1):
        safe_name = img.replace('/', '_').replace(':', '_') + ".tar"
        out_tar = os.path.join(target_dir, safe_name)

        if os.path.isfile(out_tar) and os.path.getsize(out_tar) > 1024:
            size_mb = os.path.getsize(out_tar) / (1024 * 1024)
            print(f"[{idx}/{len(IMAGES)}] ✔ Cached: {img} ({size_mb:.1f} MB)")
            success_count += 1
            continue

        print(f"[{idx}/{len(IMAGES)}] Downloading: {img} ...", flush=True)
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
