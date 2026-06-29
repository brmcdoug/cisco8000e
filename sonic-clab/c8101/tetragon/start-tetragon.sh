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
