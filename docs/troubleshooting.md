# Troubleshooting

## Feed sync is very slow / times out
- The initial **Greenbone Feed** sync can take from minutes to hours.
- Workaround: install with `--skip-feed-sync` then sync later.

## UI not reachable on https://localhost:9392/
- Check services:
  ```bash
  systemctl status gvmd gsad ospd-openvas openvasd
  ```
- If port is used, change it:
  ```bash
  ./openvas-install.sh --port 9443 --reset
  ```

## Redis socket permission errors
```bash
sudo usermod -aG redis gvm
sudo systemctl restart redis-server@openvas.service
```

## gvmd database issues
```bash
sudo systemctl status postgresql
sudo -u postgres psql -c '\du' | grep gvm || true
sudo -u postgres psql -lqt | grep gvmd || true
```

## VTs not loaded yet
```bash
journalctl -u ospd-openvas -f
journalctl -u gvmd -f
```
