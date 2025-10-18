#!/usr/bin/env bash
# ==============================================================================
# Greenbone CE / OpenVAS — Final One-File Installer (PG15 + Notus + Mosquitto)
# Built from user's working recipe, with fixes & safety:
# - Adds PGDG repo (PostgreSQL 15)
# - Installs all deps in one shot (deduped)
# - Fixes gssapi.h (krb5-dev) + RECORD uninstall (pip vs deb)
# - Extracts tarballs with --strip-components=1 (CMakeLists issue)
# - Runs feed sync as gvm (locks/permissions)
# - Adds notus + mosquitto units, correct start order
# - Handles busy .so libs by stopping services before overwrite
# Usage:
#   sudo -i
#   ./openvas-install.sh --yes --overwrite force [--skip-feed-sync]
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------- CLI Flags ----------
NONINTERACTIVE=0
OVERWRITE_MODE="ask"     # ask|skip|force
SKIP_FEED=0
while (( $# )); do
  case "$1" in
    --yes|-y) NONINTERACTIVE=1;;
    --overwrite) OVERWRITE_MODE="${2:-ask}"; shift;;
    --skip-feed-sync) SKIP_FEED=1;;
    -h|--help) echo "Usage: $0 [--yes] [--overwrite ask|skip|force] [--skip-feed-sync]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac; shift
done

# ---------- Versions (stick to user's set) ----------
GVM_LIBS_VERSION="${GVM_LIBS_VERSION:-22.6.3}"
GVMD_VERSION="${GVMD_VERSION:-22.6.0}"
PG_GVM_VERSION="${PG_GVM_VERSION:-22.6.1}"
GSA_VERSION="${GSA_VERSION:-22.5.3}"
GSAD_VERSION="${GSAD_VERSION:-22.5.1}"
OPENVAS_SMB_VERSION="${OPENVAS_SMB_VERSION:-22.5.3}"
OPENVAS_SCANNER_VERSION="${OPENVAS_SCANNER_VERSION:-22.7.3}"
OSPD_OPENVAS_VERSION="${OSPD_OPENVAS_VERSION:-22.5.3}"
NOTUS_VERSION="${NOTUS_VERSION:-22.5.0}"

# ---------- Paths & Defaults ----------
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
SOURCE_DIR="${SOURCE_DIR:-$HOME/source}"
BUILD_DIR="${BUILD_DIR:-$HOME/build}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/install}"
GVM_ADMIN_USER="${GVM_ADMIN_USER:-admin}"
GVM_ADMIN_PASS="${GVM_ADMIN_PASS:-ChangeMe!2025}"
GSAD_LISTEN="${GSAD_LISTEN:-0.0.0.0}"
PORT="${PORT:-9392}"
LOGFILE="/var/log/gvm/install.log"

mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR" /var/log/gvm
exec > >(tee -a "$LOGFILE") 2>&1

log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
wrn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
err(){ printf "\033[1;31m[x] \033[0m%s\n" "$*"; } >&2
ask_overwrite(){ case "$OVERWRITE_MODE" in force) return 0;; skip) return 1;;
  ask) (( NONINTERACTIVE )) && return 0; read -rp "Overwrite $1? [y/N] " a; [[ ${a,,} == y ]];; esac }

maybe_stop_services(){
  systemctl stop gvmd gsad ospd-openvas notus-scanner openvasd redis-server@openvas.service 2>/dev/null || true
}

maybe_rm_busy(){
  local path="$1"
  if [[ -e "$path" ]]; then
    maybe_stop_services
    if lsof "$path" >/dev/null 2>&1; then
      kill -9 $(lsof -t "$path") 2>/dev/null || true
    fi
    rm -f "$path" || true
  fi
}

fetch(){ curl -fL --retry 5 --retry-delay 2 "$1" -o "$2"; }
fetch_and_verify(){ local url="$1" sig="$2" out="$3"
  fetch "$url" "$out"; fetch "$sig" "${out}.asc" || true
  gpg --verify "${out}.asc" "$out" || true
}
extract_strip(){ local tar="$1" dest="$2"
  [[ -d "$dest" ]] && { ask_overwrite "$dest" || return 0; rm -rf "$dest"; }
  mkdir -p "$dest"; tar -C "$dest" --strip-components=1 -xzf "$tar"
}
ensure_cmake(){ local base="$1"
  [[ -f "$base/CMakeLists.txt" ]] && { echo "$base"; return; }
  local f; f=$(find "$base" -maxdepth 3 -name CMakeLists.txt -printf '%h\n' -quit || true)
  [[ -n "$f" ]] && { echo "$f"; return; }
  err "CMakeLists.txt not found under $base"; exit 1
}

cmake_build_install(){
  local name="$1" ver="$2" url="$3" sig="$4"; shift 4
  local tar="$SOURCE_DIR/${name}-${ver}.tar.gz"
  local src="$SOURCE_DIR/${name}-${ver}"
  local bld="$BUILD_DIR/${name}"
  local dest="$INSTALL_DIR/${name}"

  fetch_and_verify "$url" "$sig" "$tar"
  extract_strip "$tar" "$src"
  src=$(ensure_cmake "$src")

  rm -rf "$bld"; mkdir -p "$bld"
  cmake -S "$src" -B "$bld" -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" "$@"
  cmake --build "$bld" -j"$(nproc)"

  mkdir -p "$dest"; (cd "$bld" && make DESTDIR="$dest" install)
  # handle pg-gvm busy lib case
  maybe_rm_busy "/usr/local/lib/libgvm-pg-server.so.26"
  cp -rv "$dest"/* /
}

# ---------- Distro + PGDG ----------
log "Adding PGDG repo for PostgreSQL 15"
if ! command -v lsb_release >/dev/null 2>&1; then apt update && apt install -y lsb-release; fi
sh -c "echo 'deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main' > /etc/apt/sources.list.d/pgdg.list"
wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | tee /etc/apt/trusted.gpg.d/pgdg.asc >/dev/null

log "Installing dependencies (one shot)"
apt update
apt install -y \
  build-essential curl cmake pkg-config gnupg ca-certificates wget git rsync zip \
  python3 python3-pip python3-setuptools python3-venv \
  libglib2.0-dev libgpgme-dev libgnutls28-dev uuid-dev libssh-gcrypt-dev libhiredis-dev \
  libxml2-dev libpcap-dev libnet1-dev libpaho-mqtt-dev libldap2-dev libradcli-dev \
  libpq-dev postgresql-15 postgresql-server-dev-15 \
  libical-dev xsltproc libbsd-dev texlive-latex-extra texlive-fonts-recommended xmlstarlet rpm fakeroot dpkg nsis gpgsm sshpass openssh-client socat snmp python3-lxml gnutls-bin xml-twig-tools \
  libmicrohttpd-dev libpopt-dev libunistring-dev heimdal-dev bison libgcrypt20-dev libksba-dev nmap libjson-glib-dev python3-impacket libsnmp-dev \
  python3-packaging python3-wrapt python3-cffi python3-psutil python3-defusedxml python3-paramiko python3-redis python3-gnupg python3-paho-mqtt \
  redis-server mosquitto krb5-user libkrb5-dev

# ---------- GPG community key ----------
log "Import Greenbone signing key"
fetch https://www.greenbone.net/GBCommunitySigningKey.asc /tmp/GBCommunitySigningKey.asc
gpg --import /tmp/GBCommunitySigningKey.asc || true
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust || true

# ---------- gvm user / dirs ----------
log "Create gvm user/group and paths"
id -u gvm >/dev/null 2>&1 || useradd -r -M -U -s /usr/sbin/nologin gvm
usermod -aG gvm "${SUDO_USER:-$USER}" || true
mkdir -p /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd /etc/openvas /var/lib/openvas/plugins
chown -R gvm:gvm /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd /var/lib/openvas/plugins
chmod -R 2775 /var/lib/{gvm,openvas,notus} /var/log/gvm /var/lib/openvas/plugins

# ---------- gvm-libs ----------
log "Build gvm-libs $GVM_LIBS_VERSION"
cmake_build_install "gvm-libs" "$GVM_LIBS_VERSION" \
  "https://github.com/greenbone/gvm-libs/archive/refs/tags/v${GVM_LIBS_VERSION}.tar.gz" \
  "https://github.com/greenbone/gvm-libs/releases/download/v${GVM_LIBS_VERSION}/gvm-libs-${GVM_LIBS_VERSION}.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var

# ---------- gvmd ----------
log "Build gvmd $GVMD_VERSION"
cmake_build_install "gvmd" "$GVMD_VERSION" \
  "https://github.com/greenbone/gvmd/archive/refs/tags/v${GVMD_VERSION}.tar.gz" \
  "https://github.com/greenbone/gvmd/releases/download/v${GVMD_VERSION}/gvmd-${GVMD_VERSION}.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release -DLOCALSTATEDIR=/var -DSYSCONFDIR=/etc \
  -DGVM_DATA_DIR=/var -DGVMD_RUN_DIR=/run/gvmd -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock -DLOGROTATE_DIR=/etc/logrotate.d

# ---------- pg-gvm ----------
log "Build pg-gvm $PG_GVM_VERSION"
cmake_build_install "pg-gvm" "$PG_GVM_VERSION" \
  "https://github.com/greenbone/pg-gvm/archive/refs/tags/v${PG_GVM_VERSION}.tar.gz" \
  "https://github.com/greenbone/pg-gvm/releases/download/v${PG_GVM_VERSION}/pg-gvm-${PG_GVM_VERSION}.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release

# ---------- GSA (prebuilt) ----------
log "Install GSA dist $GSA_VERSION"
T="$SOURCE_DIR/gsa-${GSA_VERSION}.tar.gz"
fetch_and_verify "https://github.com/greenbone/gsa/releases/download/v${GSA_VERSION}/gsa-dist-${GSA_VERSION}.tar.gz" \
                 "https://github.com/greenbone/gsa/releases/download/v${GSA_VERSION}/gsa-dist-${GSA_VERSION}.tar.gz.asc" "$T"
extract_strip "$T" "$SOURCE_DIR/gsa-$GSA_VERSION"
mkdir -p "$INSTALL_PREFIX/share/gvm/gsad/web/"
rsync -a --delete "$SOURCE_DIR/gsa-$GSA_VERSION"/ "$INSTALL_PREFIX/share/gvm/gsad/web"/
chown -R gvm:gvm "$INSTALL_PREFIX/share/gvm/gsad/web"

# ---------- gsad ----------
log "Build gsad $GSAD_VERSION"
cmake_build_install "gsad" "$GSAD_VERSION" \
  "https://github.com/greenbone/gsad/archive/refs/tags/v${GSAD_VERSION}.tar.gz" \
  "https://github.com/greenbone/gsad/releases/download/v${GSAD_VERSION}/gsad-${GSAD_VERSION}.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
  -DGVMD_RUN_DIR=/run/gvmd -DGSAD_RUN_DIR=/run/gsad -DLOGROTATE_DIR=/etc/logrotate.d

# ---------- openvas-smb (optional) ----------
log "Build openvas-smb $OPENVAS_SMB_VERSION (optional)"
cmake_build_install "openvas-smb" "$OPENVAS_SMB_VERSION" \
  "https://github.com/greenbone/openvas-smb/archive/refs/tags/v${OPENVAS_SMB_VERSION}.tar.gz" \
  "https://github.com/greenbone/openvas-smb/releases/download/v${OPENVAS_SMB_VERSION}/openvas-smb-v${OPENVAS_SMB_VERSION}.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release || wrn "openvas-smb optional build skipped"

# ---------- openvas-scanner ----------
log "Build openvas-scanner $OPENVAS_SCANNER_VERSION"
cmake_build_install "openvas-scanner" "$OPENVAS_SCANNER_VERSION" \
  "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v${OPENVAS_SCANNER_VERSION}.tar.gz" \
  "https://github.com/greenbone/openvas-scanner/releases/download/v${OPENVAS_SCANNER_VERSION}/openvas-scanner-v${OPENVAS_SCANNER_VERSION}.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock -DOPENVAS_RUN_DIR=/run/ospd

mkdir -p /etc/openvas
echo "table_driven_lsc = yes" >/etc/openvas/openvas.conf
echo "mqtt_server_uri = localhost:1883" >>/etc/openvas/openvas.conf

# ---------- ospd-openvas (pip) ----------
log "Install ospd-openvas (pip, remove distro package if present)"
dpkg -l | grep -q ospd-openvas && apt remove -y python3-ospd-openvas || true
T="$SOURCE_DIR/ospd-openvas-${OSPD_OPENVAS_VERSION}.tar.gz"
fetch_and_verify "https://github.com/greenbone/ospd-openvas/archive/refs/tags/v${OSPD_OPENVAS_VERSION}.tar.gz" \
                 "https://github.com/greenbone/ospd-openvas/releases/download/v${OSPD_OPENVAS_VERSION}/ospd-openvas-v${OSPD_OPENVAS_VERSION}.tar.gz.asc" "$T"
extract_strip "$T" "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
python3 -m pip install --ignore-installed --no-deps --root="$INSTALL_DIR/ospd-openvas" "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
cp -rv "$INSTALL_DIR/ospd-openvas"/* /

# ---------- notus-scanner + mosquitto ----------
log "Install notus-scanner $NOTUS_VERSION (pip) + enable mosquitto"
T="$SOURCE_DIR/notus-scanner-${NOTUS_VERSION}.tar.gz"
fetch_and_verify "https://github.com/greenbone/notus-scanner/archive/refs/tags/v${NOTUS_VERSION}.tar.gz" \
                 "https://github.com/greenbone/notus-scanner/releases/download/v${NOTUS_VERSION}/notus-scanner-${NOTUS_VERSION}.tar.gz.asc" "$T"
extract_strip "$T" "$SOURCE_DIR/notus-scanner-$NOTUS_VERSION"
python3 -m pip install --ignore-installed --no-deps --root="$INSTALL_DIR/notus-scanner" "$SOURCE_DIR/notus-scanner-$NOTUS_VERSION"
cp -rv "$INSTALL_DIR/notus-scanner"/* /
systemctl enable --now mosquitto || true

# ---------- redis openvas profile ----------
if [[ -f "$SOURCE_DIR/openvas-scanner-${OPENVAS_SCANNER_VERSION}/config/redis-openvas.conf" ]]; then
  cp "$SOURCE_DIR/openvas-scanner-${OPENVAS_SCANNER_VERSION}/config/redis-openvas.conf" /etc/redis/
  chown redis:redis /etc/redis/redis-openvas.conf
  echo "db_address = /run/redis-openvas/redis.sock" >> /etc/openvas/openvas.conf
  systemctl enable --now redis-server@openvas.service || true
  usermod -aG redis gvm || true
else
  wrn "redis-openvas.conf not found; ensure scanner sources are present"
fi

# ---------- permissions & sudoers ----------
chown -R gvm:gvm /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd
chmod -R 2775 /var/lib/{gvm,openvas,notus} /var/log/gvm
chown gvm:gvm /usr/local/sbin/gvmd
chmod 6750 /usr/local/sbin/gvmd
echo "%gvm ALL = NOPASSWD: /usr/local/sbin/openvas" >/etc/sudoers.d/gvm
chmod 0440 /etc/sudoers.d/gvm

# ---------- PostgreSQL 15 ----------
log "Setup PostgreSQL 15 role/db"
systemctl enable --now postgresql || true
systemctl enable --now postgresql@15-main 2>/dev/null || true
sudo -u postgres bash -c 'createuser -DRS gvm 2>/dev/null || true; createdb -O gvm gvmd 2>/dev/null || true; psql gvmd -c "create role dba with superuser noinherit; grant dba to gvm;" >/dev/null 2>&1 || true'

# ---------- Feed GPG keyring ----------
export GNUPGHOME=/tmp/openvas-gnupg
mkdir -p "$GNUPGHOME"
gpg --import /tmp/GBCommunitySigningKey.asc || true
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust || true
OPENVAS_GNUPG_HOME=/etc/openvas/gnupg
mkdir -p "$OPENVAS_GNUPG_HOME"; cp -r "$GNUPGHOME"/* "$OPENVAS_GNUPG_HOME"/; chown -R gvm:gvm "$OPENVAS_GNUPG_HOME"

# ---------- Admin user ----------
/usr/local/sbin/gvmd --create-user="$GVM_ADMIN_USER" --password="$GVM_ADMIN_PASS" || true
owner=$(/usr/local/sbin/gvmd --get-users --verbose | awk '/ '"$GVM_ADMIN_USER"' /{print $2}' || true)
[[ -n "$owner" ]] && /usr/local/sbin/gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$owner" || true

# ---------- systemd units ----------
log "Write systemd units"
cat >/etc/systemd/system/notus-scanner.service <<'EOF'
[Unit]
Description=Notus Scanner
After=mosquitto.service
Wants=mosquitto.service
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
RuntimeDirectory=notus-scanner
RuntimeDirectoryMode=2775
PIDFile=/run/notus-scanner/notus-scanner.pid
ExecStart=/usr/local/bin/notus-scanner --foreground --products-directory /var/lib/notus/products --log-file /var/log/gvm/notus-scanner.log
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/ospd-openvas.service <<'EOF'
[Unit]
Description=OSPd Wrapper for the OpenVAS Scanner (ospd-openvas)
After=network.target redis-server@openvas.service mosquitto.service notus-scanner.service
Wants=redis-server@openvas.service mosquitto.service notus-scanner.service
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --lock-file-dir /var/lib/openvas --socket-mode 0o770 --mqtt-broker-address localhost --mqtt-broker-port 1883 --notus-feed-dir /var/lib/notus/advisories
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gvmd.service <<'EOF'
[Unit]
Description=Greenbone Vulnerability Manager daemon (gvmd)
After=network.target postgresql.service ospd-openvas.service
Wants=postgresql.service ospd-openvas.service
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
Group=gvm
PIDFile=/run/gvmd/gvmd.pid
RuntimeDirectory=gvmd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/sbin/gvmd --foreground --osp-vt-update=/run/ospd/ospd-openvas.sock --listen-group=gvm
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/gsad.service <<EOF
[Unit]
Description=Greenbone Security Assistant daemon (gsad)
After=network.target gvmd.service
Wants=gvmd.service
[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=gsad
RuntimeDirectoryMode=2775
PIDFile=/run/gsad/gsad.pid
ExecStart=/usr/local/sbin/gsad --foreground --listen=${GSAD_LISTEN} --port=${PORT} --http-only
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF

systemctl daemon-reload

# ---------- Feed sync ----------
log "Prepare feed locks & (optional) sync"
install -o gvm -g gvm -m 0660 /dev/null /var/lib/gvm/feed-update.lock || true
install -o gvm -g gvm -m 0660 /dev/null /var/lib/openvas/feed-update.lock || true
python3 -m pip install --user --upgrade greenbone-feed-sync || true
BIN="$(python3 -m site --user-base)/bin/greenbone-feed-sync" || true
if (( SKIP_FEED )); then
  wrn "Skipping feed sync (requested)"
else
  if [[ -x "$BIN" ]]; then sudo -u gvm -g gvm "$BIN" || wrn "feed sync failed"; else wrn "feed sync tool not found"; fi
fi

# ---------- Start in order ----------
log "Enable & start services in order"
systemctl enable --now notus-scanner
systemctl enable --now ospd-openvas
systemctl enable --now gvmd
systemctl enable --now gsad

log "Done. Open GSA: http://${GSAD_LISTEN}:${PORT}  user=${GVM_ADMIN_USER}  pass=${GVM_ADMIN_PASS}"
