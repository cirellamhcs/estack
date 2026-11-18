#!/usr/bin/env bash
# Installs Podman and gVisor (runsc) on Ubuntu/Debian. Run with sudo:
#   sudo bash install-prereqs.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

apt-get update
apt-get install -y podman passt uidmap ca-certificates curl gnupg

# gVisor apt repository (https://gvisor.dev/docs/user_guide/install/)
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://gvisor.dev/archive.key \
  | gpg --dearmor --yes -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
  > /etc/apt/sources.list.d/gvisor.list
apt-get update
apt-get install -y runsc

echo
podman --version
runsc --version | head -1
echo "Done: Podman and gVisor are installed. Next, as your normal user: ./omnigent-podman.sh setup"
