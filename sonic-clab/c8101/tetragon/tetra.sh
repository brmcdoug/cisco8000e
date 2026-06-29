#!/bin/bash
BASE="$(cd "$(dirname "$0")" && pwd)"
exec sudo "${BASE}/usr/local/bin/tetra" --server-address "unix://${BASE}/tetragon.sock" "$@"
