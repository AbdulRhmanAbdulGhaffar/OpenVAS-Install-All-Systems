# Release Notes — v1.0.0

### Highlights
- Cross-platform installer (Linux native, macOS Docker, Windows WSL2)
- Signed source builds with pinned versions
- Systemd units, Redis/PostgreSQL setup, feed sync
- Traefik reverse proxy example for HTTPS
- CI, docs, templates, utilities

### Upgrade Notes
- Backup `/var/lib/gvm` and DB before upgrading.
- Re-run installer with `--yes` to apply updates.

### Known Issues
- Initial feed sync may take long depending on network.
