#!/bin/bash
BASE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${BASE}/tetragon.pid" ]]; then
  sudo kill "$(cat "${BASE}/tetragon.pid")" 2>/dev/null || true
  rm -f "${BASE}/tetragon.pid"
fi
echo "Stopped."
