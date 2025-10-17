# Hardening Guide (Recommended)

## Network Exposure
- Put GSA behind a reverse proxy (Traefik files included).
- Restrict by firewall: allow only your IP(s).

## TLS
- Use Traefik stack with ACME/Let's Encrypt and a real domain.
- Enforce HTTPS only; no plain HTTP.

## Accounts
- Change `GVM_ADMIN_PASS` immediately.
- Create non-admin users per role.

## OS Security
- Keep host patched, enable automatic security updates.
- Limit sudoers; `gvm` group should be small and trusted.

## Backups
- Backup `/var/lib/gvm`, `/var/lib/openvas`, and DB regularly.
- Test restore before upgrades.

## Logs & Monitoring
- Forward logs to SIEM.
- Use `scripts/collect-logs.sh` for support bundles.

## Updates
- Run `greenbone-feed-sync` routinely (cron/systemd timer).
- Rebuild on major Greenbone releases to keep binaries current.
