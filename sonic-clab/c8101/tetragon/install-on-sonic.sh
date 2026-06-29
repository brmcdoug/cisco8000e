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

ssh_cmd bash -s <<REMOTE
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR}"
cat > "\${REMOTE_DIR}/start-tetragon.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="${BASE}/tetragon.pid"
LOG="${BASE}/tetragon.log"
SOCK="${BASE}/tetragon.sock"
BPF="${BASE}/usr/local/lib/tetragon/bpf"
BIN="${BASE}/usr/local/bin/tetragon"
POLICY_DIR="${BASE}/policies"

if [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
  echo "Tetragon already running (pid $(cat "${PIDFILE}"))"
  exit 0
fi

sudo "${BIN}" \
  --bpf-lib "${BPF}" \
  --server-address "unix://${SOCK}" \
  --tracing-policy-dir "${POLICY_DIR}" \
  --export-filename "${LOG}" \
  > "${BASE}/tetragon-stdout.log" 2>&1 &
echo $! | sudo tee "${PIDFILE}" >/dev/null
sleep 2
echo "Tetragon started (pid $(cat "${PIDFILE}")). Events: ${LOG}"
EOF

cat > "\${REMOTE_DIR}/tetra.sh" <<'EOF'
#!/bin/bash
BASE="$(cd "$(dirname "$0")" && pwd)"
exec sudo "${BASE}/usr/local/bin/tetra" --server-address "unix://${BASE}/tetragon.sock" "$@"
EOF

cat > "\${REMOTE_DIR}/stop-tetragon.sh" <<'EOF'
#!/bin/bash
BASE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${BASE}/tetragon.pid" ]]; then
  sudo kill "$(cat "${BASE}/tetragon.pid")" 2>/dev/null || true
  rm -f "${BASE}/tetragon.pid"
fi
echo "Stopped."
EOF

chmod +x "\${REMOTE_DIR}/start-tetragon.sh" "\${REMOTE_DIR}/tetra.sh" "\${REMOTE_DIR}/stop-tetragon.sh"
REMOTE

chmod +x "${SCRIPT_DIR}/install-on-sonic.sh"

echo ""
echo "On the SONiC guest:"
echo "  ssh ${SONIC_SSH}   # password: ${SONIC_PASS}"
echo "  ${REMOTE_DIR}/start-tetragon.sh"
echo "  ${REMOTE_DIR}/tetra.sh getevents -o compact"
echo ""
echo "To enable blocking later, scp deny-write-home-admin-test-enforce.yaml into"
echo "  ${REMOTE_DIR}/policies/  (remove the -observe.yaml), then stop/start Tetragon."
