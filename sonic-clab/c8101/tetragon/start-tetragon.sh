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

if [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
  echo "Tetragon already running (pid $(cat "${PIDFILE}"))"
  exit 0
fi

rm -f "${PIDFILE}" "${SOCK}"

sudo "${BIN}" \
  --bpf-lib "${BPF}" \
  --server-address "unix://${SOCK}" \
  --tracing-policy-dir "${POLICY_DIR}" \
  --export-filename "${LOG}" \
  > "${STDOUT}" 2>&1 &
echo $! | sudo tee "${PIDFILE}" >/dev/null

sleep 3
PID="$(cat "${PIDFILE}")"
if ! kill -0 "${PID}" 2>/dev/null; then
  echo "ERROR: Tetragon exited immediately (pid ${PID}). Last log lines:"
  tail -n 40 "${STDOUT}" 2>/dev/null || true
  rm -f "${PIDFILE}" "${SOCK}"
  echo ""
  echo "If the log mentions sys_openat or policy load failure, try the fallback policy:"
  echo "  mv ${POLICY_DIR}/deny-write-home-admin-test-enforce.yaml ${POLICY_DIR}/disabled/"
  echo "  cp ${BASE}/deny-write-home-admin-test-enforce-fallback.yaml ${POLICY_DIR}/"
  echo "  ${BASE}/start-tetragon.sh"
  exit 1
fi

echo "Tetragon running (pid ${PID}). Events: ${LOG}"
