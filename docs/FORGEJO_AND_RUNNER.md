# Forgejo & CI/CD Runner Operations Guide

This guide covers administering Forgejo, configuring Forgejo Actions workflows, and managing the Docker-in-Docker CI/CD runner.

---

## 1. How the Runner Works in k3s

The runner is deployed as a Kubernetes `StatefulSet` with two co-located containers in the same Pod:
1. **`dind`**: Runs `docker:27-dind` in privileged mode, publishing `/var/run/docker.sock` to an `emptyDir` volume.
2. **`runner`**: Runs `code.forgejo.org/forgejo/runner:4.0.1`. It connects to `/var/run/docker.sock` to launch containers dynamically for each CI workflow step.

### Key Benefits:
- **Zero Host Contamination**: CI containers are created inside DinD, not on the host node's containerd socket.
- **Full Docker Support**: Supports building Docker images (`docker build`), running multi-container tests (`docker-compose`), and caching layers across jobs.
- **Stateful Registration**: Runner credentials are stored in `/data/.runner` on a PersistentVolumeClaim. Reboots do NOT create duplicate ghost runners in Forgejo!

---

## 2. Auto-Registration & Manual Token Generation

When deploying with Ansible, the runner token is automatically discovered using `forgejo-cli` directly inside the Forgejo pod.

If you ever need to manually re-register the runner:
```bash
./scripts/register-forgejo-runner.sh
```

Or pass a specific token from Forgejo UI (**Site Administration** -> **Actions** -> **Runners** -> **Create new Runner**):
```bash
./scripts/register-forgejo-runner.sh <TOKEN>
```

---

## 3. Sample Workflow Configuration

Create `.forgejo/workflows/ci.yaml` in your Git repository:

```yaml
name: Continuous Integration
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Setup Node.js Environment
        uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install Dependencies & Run Tests
        run: |
          npm ci
          npm test

  build-container:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Build Docker Image
        run: |
          docker build -t my-app:${{ github.sha }} .
          docker images
```

---

## 4. Runner Labels & Custom Images

The default runner supports the following labels:
- `ubuntu-latest:docker://node:20-bookworm`
- `ubuntu-22.04:docker://node:20-bookworm`
- `docker:docker://docker:27-cli`

To add custom images (e.g. Python, Golang, or Rust), edit `forgejo_runner_labels` in [inventory/group_vars/all.yml](file:///home/dsv/work/pipeline/inventory/group_vars/all.yml) or update [manifests/forgejo-runner/runner-configmap.yaml](file:///home/dsv/work/pipeline/manifests/forgejo-runner/runner-configmap.yaml).
