# Uninstall / Cleanup

## Native installation
```bash
./openvas-install.sh --uninstall
```

## Docker stack
```bash
cd docker
docker compose down -v
```

> Back up reports and DB before uninstalling.
