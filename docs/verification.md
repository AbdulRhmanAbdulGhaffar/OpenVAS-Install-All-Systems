# Verification

## Services
```bash
systemctl status gvmd gsad ospd-openvas openvasd
journalctl -u gvmd -e --no-pager
journalctl -u gsad -e --no-pager
```

## Database
```bash
sudo -u postgres psql -c "\l" | grep gvmd || true
```

## Web UI
- Open `https://localhost:9392/`
- Login with `admin` / the password you set (`GVM_ADMIN_PASS`).
- Create a target and run **Full and fast** scan.
