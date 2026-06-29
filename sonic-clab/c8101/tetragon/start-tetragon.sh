#!/bin/bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
PIDFILE="${BASE}/tetragon.pid"
LOG="${BASE}/tetragon.log"
STDOUT="${BASE}/tetragon-stdout.log"
SOCK="${BASE}/tetragon.sock"
BPF="${BASE}/usr/local/lib/tetragon/bpf"
BIN="${BASE}/usr/local/bin/tetragon"
POLICY_DIR="${BASE}/policies"

if pgrep -f "${BASE}/usr/local/bin/tetragon" >/dev/null 2>&1; then
  echo "Tetragon already running (pid $(pgrep -f "${BASE}/usr/local/bin/tetragon" | head -1))"
  exit 0
fi

rm -f "${PIDFILE}" "${SOCK}"
: > "${STDOUT}"

sudo nohup "${BIN}" \
  --bpf-lib "${BPF}" \
  --server-address "unix://${SOCK}" \
  --tracing-policy-dir "${POLICY_DIR}" \
  --export-filename "${LOG}" \
  >> "${STDOUT}" 2>&1 &

sleep 5

if grep -q "Failed to execute tetragon" "${STDOUT}" 2>/dev/null; then
  echo "ERROR: Tetragon failed to start. Log tail:"
  tail -n 20 "${STDOUT}" || true
  rm -f "${PIDFILE}" "${SOCK}"
  exit 1
fi

PID="$(pgrep -f "${BASE}/usr/local/bin/tetragon" | head -1 || true)"
if [[ -z "${PID}" ]]; then
  echo "ERROR: Tetragon process not found. Log tail:"
  tail -n 30 "${STDOUT}" || true
  rm -f "${PIDFILE}" "${SOCK}"
  exit 1
fi

echo "${PID}" > "${PIDFILE}"
echo "Tetragon running (pid ${PID}). Events: ${LOG}"
