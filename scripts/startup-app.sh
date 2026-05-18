#!/usr/bin/env bash
# =============================================================================
# Startup script for the APP VM.
# Runs as root on first boot. We use it to install Docker + the gcloud auth
# helper for Artifact Registry. The actual app image is pulled and started by
# the CI/CD pipeline (chapter 09) — NOT here.
# =============================================================================
set -euo pipefail

apt-get update -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    docker.io

systemctl enable --now docker

# Add a docker group + add the default user so `docker ps` works after SSH.
usermod -aG docker $(getent passwd 1000 | cut -d: -f1) || true

# Configure Docker to authenticate to Artifact Registry using the VM's
# attached service account. The region is filled in by the pipeline via
# instance metadata in chapter 09.
mkdir -p /etc/systemd/system/docker.service.d

date -Iseconds > /var/log/startup-complete.log
echo "[startup-app] done"
