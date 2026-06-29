#!/usr/bin/env bash
# Copy Tetragon + demo policies onto a virtualized SONiC node (the QEMU guest you SSH into).
# Run from your Containerlab host — not from the outer clab container.
#
# Usage:
#   ./install-on-sonic.sh admin@172.20.2.100
#   SONIC_PASS=password ./install-on-sonic.sh admin@172.20.2.100
#
set -euo pipefail

SONIC_SSH="${1:-${SONIC_SSH:-admin@172.20.2.100}}"
SONIC_PASS="${SONIC_PASS:-password}"
TETRAGON_VERSION="${TETRAGON_VERSION:-v1.7.0}"
TARBALL="tetragon-${TETRAGON_VERSION}-amd64.tar.gz"
URL="https://github.com/cilium/tetragon/releases/download/${TETRAGON_VERSION}/${TARBALL}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR="/home/admin/tetragon"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ssh_cmd() {
  sshpass -p "${SONIC_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SONIC_SSH}" "$@"
}

scp_cmd() {
  sshpass -p "${SONIC_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

if ! command -v sshpass >/dev/null 2>&1; then
  echo "Install sshpass, or configure SSH keys and remove sshpass from this script."
  exit 1
fi

echo "==> Checking SONiC guest prerequisites on ${SONIC_SSH}"
ssh_cmd bash -s <<'CHECK'
set -e
echo "kernel: $(uname -r)"
if [[ -f /sys/kernel/btf/vmlinux ]]; then
  echo "BTF: present"
else
  echo "BTF: MISSING — Tetragon v1.x needs CONFIG_DEBUG_INFO_BTF on this SONiC kernel."
  exit 1
fi
CHECK

echo "==> Downloading ${URL}"
curl -fsSL -o "${WORK}/${TARBALL}" "${URL}"
tar -C "${WORK}" -xzf "${WORK}/${TARBALL}"

echo "==> Uploading to ${SONIC_SSH}:${REMOTE_DIR}"
ssh_cmd "rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR}/policies"
scp_cmd -r "${WORK}/tetragon-${TETRAGON_VERSION}-amd64/"* "${SONIC_SSH}:${REMOTE_DIR}/"
scp_cmd "${SCRIPT_DIR}/deny-write-home-admin-test-observe.yaml" "${SONIC_SSH}:${REMOTE_DIR}/policies/"
scp_cmd "${SCRIPT_DIR}/deny-write-home-admin-test-enforce-fallback.yaml" "${SONIC_SSH}:${REMOTE_DIR}/"
scp_cmd "${SCRIPT_DIR}/start-tetragon.sh" "${SCRIPT_DIR}/tetra.sh" "${SCRIPT_DIR}/stop-tetragon.sh" \
  "${SONIC_SSH}:${REMOTE_DIR}/"
ssh_cmd "chmod +x ${REMOTE_DIR}/start-tetragon.sh ${REMOTE_DIR}/tetra.sh ${REMOTE_DIR}/stop-tetragon.sh"

echo ""
echo "Install complete on ${SONIC_SSH}."
echo ""
echo "On the SONiC guest:"
echo "  ssh ${SONIC_SSH}   # password: ${SONIC_PASS}"
echo "  ${REMOTE_DIR}/start-tetragon.sh"
echo "  ${REMOTE_DIR}/tetra.sh getevents -o compact"
echo ""
echo "To enable blocking later, scp deny-write-home-admin-test-enforce.yaml into"
echo "  ${REMOTE_DIR}/policies/  (remove the -observe.yaml), then stop/start Tetragon."
