#!/usr/bin/env bash
set -euo pipefail
OUT="openvas-support-$(date +%Y%m%d-%H%M%S).tar.gz"
TMP="$(mktemp -d)"
mkdir -p "$TMP/logs"

echo "[*] Gathering logs and status..."
{
  echo "== Services =="
  systemctl status gvmd gsad ospd-openvas openvasd --no-pager || true
  echo "== Versions =="
  gvmd --version || true
  gsad --version || true
  openvas --version || true
} &> "$TMP/summary.txt"

journalctl -u gvmd -u gsad -u ospd-openvas -u openvasd --no-pager -n 20000 > "$TMP/logs/systemd.log" || true
cp -r /var/log/gvm "$TMP/logs/" 2>/dev/null || true

tar -C "$TMP" -czf "$OUT" .
rm -rf "$TMP"
echo "Created $OUT"
