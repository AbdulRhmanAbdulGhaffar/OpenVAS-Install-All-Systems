#!/usr/bin/env bash
set -euo pipefail
echo "== OpenVAS Preflight Check =="

ok=1
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; ok=0; }; }

echo "[*] Checking essentials..."
for c in curl cmake gcc g++ make tar gpg; do need "$c"; done

if ! id -u gvm >/dev/null 2>&1; then
  echo "[!] 'gvm' user not found (will be created by installer)"
fi

if [ -f /etc/os-release ]; then . /etc/os-release; echo "[*] OS: $PRETTY_NAME"; fi

echo "[*] Disk space:"
df -h . | tail -n +2

echo "[*] Memory:"
free -h || true

if [ "$ok" -eq 1 ]; then
  echo "Preflight OK ✅"
  exit 0
else
  echo "Preflight failed ❌ — install missing deps above then re-run."
  exit 1
fi
