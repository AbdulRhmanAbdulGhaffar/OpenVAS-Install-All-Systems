#!/usr/bin/env bash
# ==============================================================================
# OpenVAS / Greenbone Community Edition — Universal Installer (FINAL)
# Author: AbdulRhman AbdulGhaffar
# Repo  : https://github.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems
# License: MIT
#
# Highlights:
# - GitHub tarballs extracted with --strip-components=1 (fix nested top-dir)
# - Switches: --yes, --overwrite {ask|skip|force}, --reuse-sources
# - ospd-openvas: remove distro pkg; pip install with --ignore-installed to DESTDIR
# - Kerberos headers (libkrb5-dev/krb5-devel) for gssapi.h
# - Robust Rust build for openvasd (CARGO_TARGET_DIR + deps dir)
# - Feed sync runs as user gvm with fixed ownership/permissions
# - systemd units for ospd-openvas, gvmd, gsad, openvasd
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------- Defaults ----------------
OS_ID=""; PORT=9392; WITH_POSTGRES=1; NO_SUDO=0
SKIP_FEED=0; NONINTERACTIVE=0; VERBOSE=0; UNINSTALL=0
OVERWRITE_MODE="ask"     # ask|skip|force
REUSE_SOURCES=0          # 0/1 -> --reuse-sources

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
GVM_ADMIN_USER="${GVM_ADMIN_USER:-admin}"
GVM_ADMIN_PASS="${GVM_ADMIN_PASS:-ChangeMe!2025}"

# Official docs versions (can be overridden via env)
GVM_LIBS_VERSION="${GVM_LIBS_VERSION:-22.22.0}"
GVMD_VERSION="${GVMD_VERSION:-26.0.0}"
PG_GVM_VERSION="${PG_GVM_VERSION:-22.6.9}"
GSA_VERSION="${GSA_VERSION:-25.0.0}"
GSAD_VERSION="${GSAD_VERSION:-24.3.0}"
OPENVAS_SMB_VERSION="${OPENVAS_SMB_VERSION:-22.5.3}"
OPENVAS_SCANNER_VERSION="${OPENVAS_SCANNER_VERSION:-23.20.1}"
OSPD_OPENVAS_VERSION="${OSPD_OPENVAS_VERSION:-22.9.0}"
OPENVAS_DAEMON="${OPENVAS_DAEMON:-23.20.0}"

SOURCE_DIR="${SOURCE_DIR:-$HOME/source}"
BUILD_DIR="${BUILD_DIR:-$HOME/build}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/install}"
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"

# ---------------- Logging ----------------
LOGFILE="/var/log/gvm/install.log"
mkdir -p /var/log/gvm 2>/dev/null || true
exec > >(tee -a "$LOGFILE") 2>&1

# ---------------- Utils ----------------
log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
wrn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
err(){ printf "\033[1;31m[x] \033[0m%s\n" "$*"; } >&2
run(){ if (( VERBOSE )); then set -x; fi; "$@"; if (( VERBOSE )); then set +x; fi; }
maybe_sudo(){ if (( NO_SUDO )); then "$@"; else sudo "$@"; fi; }

usage(){ cat <<EOF
Usage: $0 [OPTIONS]
  --port <num>         GSA port (default 9392)
  --no-postgres        Skip local PostgreSQL setup
  --skip-feed-sync     Don't run initial feed sync
  --overwrite <ask|skip|force>  Overwrite policy for existing folders (default ask)
  --reuse-sources      Reuse existing extracted sources (skip untar)
  --yes|-y             Non-interactive mode
  --verbose            Verbose output
  --uninstall          Remove all services and data
  -h|--help            Show help
EOF
}

# ---------------- Arg Parse ----------------
while (( $# )); do case "$1" in
  --port) PORT="$2"; shift;;
  --no-postgres) WITH_POSTGRES=0;;
  --skip-feed-sync) SKIP_FEED=1;;
  --overwrite) OVERWRITE_MODE="$2"; shift;;
  --reuse-sources) REUSE_SOURCES=1;;
  --yes|-y) NONINTERACTIVE=1;;
  --verbose) VERBOSE=1;;
  --uninstall) UNINSTALL=1;;
  -h|--help) usage; exit 0;;
  *) err "Unknown option: $1"; usage; exit 2;;
esac; shift; done

ask_overwrite(){
  local path="$1"
  case "$OVERWRITE_MODE" in
    force) return 0;;
    skip)  return 1;;
    ask)
      if (( NONINTERACTIVE )); then return 0; fi
      read -rp "[?] '$path' exists. overwrite? [y/N] " ans
      [[ "${ans,,}" == "y" ]]
    ;;
  esac
}

fetch(){ curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 "$1" -o "$2"; }
fetch_and_verify(){ # <url_tar> <url_sig> <out_tar>
  local url="$1" sig="$2" tar="$3" asc="${3}.asc"
  if ! (( REUSE_SOURCES )) || [[ ! -f "$tar" ]]; then
    fetch "$url" "$tar"; fetch "$sig" "$asc"
  else wrn "Using existing tar: $tar"; fi
  gpg --verify "$asc" "$tar"
}

# Extract tarballs removing the top-level dir (fix nested)
extract_clean(){ # <tar.gz> <target_dir>
  local tarfile="$1" target="$2"
  if (( REUSE_SOURCES )) && [[ -d "$target" ]]; then
    wrn "REUSE_SOURCES=1 -> using existing: $target"; return 0; fi
  if [[ -d "$target" ]]; then
    case "$OVERWRITE_MODE" in
      force) rm -rf "$target";;
      skip)  wrn "SKIP extract (exists): $target"; return 0;;
      ask)   ask_overwrite "$target" || { wrn "SKIP extract: $target"; return 0; }
             rm -rf "$target";;
    esac
  fi
  mkdir -p "$target"
  tar -C "$target" --strip-components=1 -xzf "$tarfile"
}

ensure_cmake_src(){ # <base_dir>  -> echoes the dir containing CMakeLists.txt
  local base="$1"
  [[ -f "$base/CMakeLists.txt" ]] && { printf "%s\n" "$base"; return 0; }
  local found; found="$(find "$base" -maxdepth 3 -type f -name CMakeLists.txt -printf '%h\n' -quit || true)"
  [[ -n "$found" ]] && printf "%s\n" "$found" || { err "CMakeLists.txt not found under $base"; return 1; }
}

build_cmake_component(){ # <name> <version> <url_tar> <url_sig> <cmake-args...>
  local NAME="$1" VER="$2" URL="$3" SIG="$4"; shift 4
  local TAR="$SOURCE_DIR/${NAME}-${VER}.tar.gz"
  local SRC_DIR="$SOURCE_DIR/${NAME}-${VER}"
  local BLD_DIR="$BUILD_DIR/${NAME}"
  local INS_DIR="$INSTALL_DIR/${NAME}"
  fetch_and_verify "$URL" "$SIG" "$TAR"
  extract_clean "$TAR" "$SRC_DIR"
  SRC_DIR="$(ensure_cmake_src "$SRC_DIR")"
  [[ -d "$BLD_DIR" ]] && rm -rf "$BLD_DIR"
  cmake -S "$SRC_DIR" -B "$BLD_DIR" "$@"
  cmake --build "$BLD_DIR" -j"$(nproc)"
  mkdir -p "$INS_DIR" && cd "$BLD_DIR"
  make DESTDIR="$INS_DIR" install
  if (( NO_SUDO )); then cp -rv "$INS_DIR"/* /; else sudo cp -rv "$INS_DIR"/* /; fi
}

# ---------------- Detect OS ----------------
if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-ubuntu}"; else OS_ID="ubuntu"; fi

# ---------------- Uninstall ----------------
if (( UNINSTALL )); then
  wrn "Uninstalling GVM/OpenVAS (services & data)."
  set +e
  maybe_sudo systemctl stop gvmd gsad ospd-openvas openvasd 2>/dev/null
  maybe_sudo systemctl disable gvmd gsad ospd-openvas openvasd 2>/dev/null
  maybe_sudo rm -f /etc/systemd/system/{gvmd,gsad,ospd-openvas,openvasd}.service
  maybe_sudo systemctl daemon-reload
  maybe_sudo rm -rf /var/lib/{gvm,openvas,notus} /var/log/gvm /etc/openvas /run/gvmd
  maybe_sudo userdel gvm 2>/dev/null || true
  maybe_sudo groupdel gvm 2>/dev/null || true
  set -e; log "Uninstall finished."; exit 0
fi

# ---------------- Base deps ----------------
log "Base dependencies on $OS_ID"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt update
  run sudo apt install -y build-essential curl cmake pkg-config python3 python3-pip gnupg ca-certificates rsync git wget
elif [[ "$OS_ID" =~ fedora|rhel|rocky|alma|centos ]]; then
  run sudo dnf -y install @"Development Tools" curl cmake pkgconf-pkg-config python3 python3-pip gnupg2 rsync git wget
else
  wrn "Untested distro; the script targets Debian/Ubuntu primarily."
fi

# ---------------- GPG key ----------------
if ! gpg -k 8AE4BE429B60A59B311C2E739823FAA60ED1E580 >/dev/null 2>&1; then
  fetch https://www.greenbone.net/GBCommunitySigningKey.asc /tmp/GBCommunitySigningKey.asc
  gpg --import /tmp/GBCommunitySigningKey.asc || true
  echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust || true
fi

# ---------------- gvm user & dirs ----------------
if ! id -u gvm >/dev/null 2>&1; then maybe_sudo useradd -r -M -U -s /usr/sbin/nologin gvm; fi
maybe_sudo usermod -aG gvm "$USER" || true
maybe_sudo mkdir -p /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd /etc/openvas /var/lib/openvas/plugins
maybe_sudo chown -R gvm:gvm /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd
maybe_sudo chmod -R 2775 /var/lib/{gvm,openvas,notus} /var/log/gvm

# ---------------- Redis & Postgres ----------------
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y redis-server
  (( WITH_POSTGRES )) && run sudo apt install -y postgresql postgresql-server-dev-all
elif [[ "$OS_ID" =~ fedora|rhel|rocky|alma|centos ]]; then
  run sudo dnf -y install redis
  (( WITH_POSTGRES )) && run sudo dnf -y install postgresql-server postgresql-devel
fi

# ---------------- gvm-libs ----------------
log "Build gvm-libs $GVM_LIBS_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y libcjson-dev libcurl4-gnutls-dev libgcrypt-dev libglib2.0-dev \
    libgnutls28-dev libgpgme-dev libhiredis-dev libnet1-dev libpaho-mqtt-dev \
    libpcap-dev libssh-dev libxml2-dev uuid-dev libldap2-dev libradcli-dev
fi
build_cmake_component "gvm-libs" "$GVM_LIBS_VERSION" \
  "https://github.com/greenbone/gvm-libs/archive/refs/tags/v$GVM_LIBS_VERSION.tar.gz" \
  "https://github.com/greenbone/gvm-libs/releases/download/v$GVM_LIBS_VERSION/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var

# ---------------- gvmd ----------------
log "Build gvmd $GVMD_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y libbsd-dev libcjson-dev libglib2.0-dev libgnutls28-dev libgpgme-dev libical-dev libpq-dev rsync xsltproc
fi
build_cmake_component "gvmd" "$GVMD_VERSION" \
  "https://github.com/greenbone/gvmd/archive/refs/tags/v$GVMD_VERSION.tar.gz" \
  "https://github.com/greenbone/gvmd/releases/download/v$GVMD_VERSION/gvmd-$GVMD_VERSION.tar.gz.asc" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DLOCALSTATEDIR=/var -DSYSCONFDIR=/etc -DGVM_DATA_DIR=/var \
  -DGVM_LOG_DIR=/var/log/gvm -DGVMD_RUN_DIR=/run/gvmd \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
  -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock -DLOGROTATE_DIR=/etc/logrotate.d

# ---------------- pg-gvm ----------------
log "Build pg-gvm $PG_GVM_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then run sudo apt install -y libglib2.0-dev libical-dev postgresql-server-dev-all; fi
build_cmake_component "pg-gvm" "$PG_GVM_VERSION" \
  "https://github.com/greenbone/pg-gvm/archive/refs/tags/v$PG_GVM_VERSION.tar.gz" \
  "https://github.com/greenbone/pg-gvm/releases/download/v$PG_GVM_VERSION/pg-gvm-$PG_GVM_VERSION.tar.gz.asc" \
  -DCMAKE_BUILD_TYPE=Release

# ---------------- GSA dist ----------------
log "Install GSA dist $GSA_VERSION"
T="$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz" \
  "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc" \
  "$T"
SRC_DIR="$SOURCE_DIR/gsa-$GSA_VERSION"; extract_clean "$T" "$SRC_DIR"
maybe_sudo mkdir -p "$INSTALL_PREFIX/share/gvm/gsad/web/"
rsync -a --delete "$SRC_DIR"/ "$INSTALL_PREFIX/share/gvm/gsad/web"/

# ---------------- gsad ----------------
log "Build gsad $GSAD_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then run sudo apt install -y libbrotli-dev libglib2.0-dev libgnutls28-dev libmicrohttpd-dev libxml2-dev; fi
build_cmake_component "gsad" "$GSAD_VERSION" \
  "https://github.com/greenbone/gsad/archive/refs/tags/v$GSAD_VERSION.tar.gz" \
  "https://github.com/greenbone/gsad/releases/download/v$GSAD_VERSION/gsad-$GSAD_VERSION.tar.gz.asc" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad -DGVM_LOG_DIR=/var/log/gvm -DLOGROTATE_DIR=/etc/logrotate.d

# ---------------- openvas-smb (optional) ----------------
log "Build openvas-smb $OPENVAS_SMB_VERSION (optional)"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y gcc-mingw-w64 libgnutls28-dev libglib2.0-dev libpopt-dev libunistring-dev heimdal-multidev perl-base
fi
build_cmake_component "openvas-smb" "$OPENVAS_SMB_VERSION" \
  "https://github.com/greenbone/openvas-smb/archive/refs/tags/v$OPENVAS_SMB_VERSION.tar.gz" \
  "https://github.com/greenbone/openvas-smb/releases/download/v$OPENVAS_SMB_VERSION/openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release || wrn "openvas-smb optional build issue"

# ---------------- openvas-scanner ----------------
log "Build openvas-scanner $OPENVAS_SCANNER_VERSION"
case "$OS_ID" in
  ubuntu|debian|kali)
    run sudo apt install -y bison libglib2.0-dev libgnutls28-dev libgcrypt20-dev libpcap-dev \
      libgpgme-dev libksba-dev rsync nmap libjson-glib-dev libcurl4-gnutls-dev libbsd-dev \
      libkrb5-dev python3-impacket libsnmp-dev doxygen pandoc ;;
  fedora|rhel|rocky|alma|centos)
    run sudo dnf -y install krb5-devel ;;
esac
build_cmake_component "openvas-scanner" "$OPENVAS_SCANNER_VERSION" \
  "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_SCANNER_VERSION.tar.gz" \
  "https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_SCANNER_VERSION/openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock \
  -DOPENVAS_RUN_DIR=/run/ospd

maybe_sudo mkdir -p /etc/openvas
echo "table_driven_lsc = yes" | maybe_sudo tee /etc/openvas/openvas.conf >/dev/null
echo "openvasd_server = http://127.0.0.1:3000" | maybe_sudo tee -a /etc/openvas/openvas.conf >/dev/null

# ---------------- ospd-openvas (pip vs distro fix) ----------------
log "Install ospd-openvas $OSPD_OPENVAS_VERSION (pip over distro)"
if command -v dpkg >/dev/null 2>&1 && dpkg -s python3-ospd-openvas >/dev/null 2>&1; then
  wrn "Removing Debian package python3-ospd-openvas"; sudo apt remove -y python3-ospd-openvas || true
fi
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y python3 python3-pip python3-setuptools python3-packaging python3-wrapt \
    python3-cffi python3-psutil python3-lxml python3-defusedxml python3-paramiko \
    python3-redis python3-gnupg python3-paho-mqtt
fi
T="$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$OSPD_OPENVAS_VERSION.tar.gz" \
  "https://github.com/greenbone/ospd-openvas/releases/download/v$OSPD_OPENVAS_VERSION/ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc" \
  "$T"
SRC_DIR="$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"; extract_clean "$T" "$SRC_DIR"
mkdir -p "$INSTALL_DIR/ospd-openvas"; cd "$SRC_DIR"
python3 -m pip install --ignore-installed --no-deps --no-warn-script-location --root="$INSTALL_DIR/ospd-openvas" .
maybe_sudo cp -rv "$INSTALL_DIR/ospd-openvas"/* /

# ---------------- openvasd (Rust) ----------------
log "Build openvasd $OPENVAS_DAEMON (rust)"
build_openvasd(){
  local SRC_DIR="$1"
  if ! command -v cargo >/dev/null 2>&1; then curl https://sh.rustup.rs -sSf | sh -s -- -y; source "$HOME/.cargo/env"; fi
  case "$OS_ID" in
    ubuntu|debian|kali) sudo apt install -y pkg-config libssl-dev || true ;;
    fedora|rhel|rocky|alma|centos) sudo dnf -y install openssl-devel || true ;;
  esac
  rustup update stable || true
  export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
  export RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}
  export CARGO_TARGET_DIR="$SRC_DIR/rust/target"
  mkdir -p "$CARGO_TARGET_DIR/release/deps"
  ( cd "$SRC_DIR/rust/src/openvasd" && cargo build --release )
  ( cd "$SRC_DIR/rust/src/scannerctl" && cargo build --release )
  install -D -m 0755 "$CARGO_TARGET_DIR/release/openvasd" /usr/local/bin/openvasd || true
  install -D -m 0755 "$CARGO_TARGET_DIR/release/scannerctl" /usr/local/bin/scannerctl || true
}
T="$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_DAEMON.tar.gz" \
  "https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_DAEMON/openvas-scanner-v$OPENVAS_DAEMON.tar.gz.asc" \
  "$T"
SRC_DIR="$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON"; extract_clean "$T" "$SRC_DIR"
build_openvasd "$SRC_DIR"

# ---------------- Redis config ----------------
log "Configure Redis for OpenVAS"
if [[ -f "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" ]]; then
  maybe_sudo cp "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" /etc/redis/
  maybe_sudo chown redis:redis /etc/redis/redis-openvas.conf
  echo "db_address = /run/redis-openvas/redis.sock" | maybe_sudo tee -a /etc/openvas/openvas.conf >/dev/null
  maybe_sudo systemctl enable --now redis-server@openvas.service || true
  maybe_sudo usermod -aG redis gvm || true
fi

# ---------------- Permissions & sudoers ----------------
log "Permissions & sudoers"
maybe_sudo mkdir -p /var/lib/notus /run/gvmd
maybe_sudo chown -R gvm:gvm /var/lib/gvm /var/lib/openvas /var/lib/notus /var/log/gvm /run/gvmd
maybe_sudo chmod -R 2775 /var/lib/gvm /var/lib/openvas /var/lib/notus /var/log/gvm
if [[ -x "$INSTALL_PREFIX/sbin/gvmd" ]]; then
  maybe_sudo chown gvm:gvm "$INSTALL_PREFIX/sbin/gvmd"
  maybe_sudo chmod 6750 "$INSTALL_PREFIX/sbin/gvmd"
fi
echo "%gvm ALL = NOPASSWD: $INSTALL_PREFIX/sbin/openvas" | sudo tee /etc/sudoers.dumps >/dev/null
maybe_sudo install -m 0440 /etc/sudoers.dumps /etc/sudoers.d/gvm; maybe_sudo rm -f /etc/sudoers.dumps

# ---------------- PostgreSQL ----------------
if (( WITH_POSTGRES )); then
  log "Setup PostgreSQL"
  sudo systemctl start postgresql || sudo systemctl start postgresql@15-main || true
  sudo -u postgres bash -c 'createuser -DRS gvm 2>/dev/null || true; createdb -O gvm gvmd 2>/dev/null || true; psql gvmd -c "create role dba with superuser noinherit; grant dba to gvm;" >/dev/null 2>&1 || true'
fi

# ---------------- Feed keyring ----------------
log "Prepare GPG keyring for feed validation"
export GNUPGHOME=/tmp/openvas-gnupg; mkdir -p "$GNUPGHOME"
fetch https://www.greenbone.net/GBCommunitySigningKey.asc /tmp/GBCommunitySigningKey.asc || true
gpg --import /tmp/GBCommunitySigningKey.asc || true
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust || true
export OPENVAS_GNUPG_HOME=/etc/openvas/gnupg
maybe_sudo mkdir -p "$OPENVAS_GNUPG_HOME"
maybe_sudo cp -r "$GNUPGHOME"/* "$OPENVAS_GNUPG_HOME"/ || true
maybe_sudo chown -R gvm:gvm "$OPENVAS_GNUPG_HOME"

# ---------------- Admin & Feed Owner ----------------
log "Create admin & set Feed Import Owner"
if [[ -x "$INSTALL_PREFIX/sbin/gvmd" ]]; then
  maybe_sudo "$INSTALL_PREFIX/sbin/gvmd" --create-user="$GVM_ADMIN_USER" --password="$GVM_ADMIN_PASS" || true
  owner=$($INSTALL_PREFIX/sbin/gvmd --get-users --verbose | awk '/ '"$GVM_ADMIN_USER"' /{print $2}') || owner=""
  [[ -n "$owner" ]] && maybe_sudo "$INSTALL_PREFIX/sbin/gvmd" --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$owner" || true
fi

# ---------------- systemd units ----------------
log "Install systemd units"
mkunit(){
  local name="$1" body="$2" tmp="$BUILD_DIR/$1.service"
  printf "%s" "$body" > "$tmp"
  if [[ -e "/etc/systemd/system/$1.service" ]] && ! ask_overwrite "/etc/systemd/system/$1.service"; then
    wrn "SKIP unit $1 (exists)"; return
  fi
  maybe_sudo install -m 0644 "$tmp" "/etc/systemd/system/$1.service"
}
mkunit "ospd-openvas" "[Unit]
Description=OSPd Wrapper for OpenVAS
After=network.target redis-server@openvas.service openvasd.service
Wants=redis-server@openvas.service openvasd.service
[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --lock-file-dir /var/lib/openvas --socket-mode 0o770 --notus-feed-dir /var/lib/notus/advisories
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
"
mkunit "gvmd" "[Unit]
Description=Greenbone Vulnerability Manager daemon (gvmd)
After=network.target postgresql.service ospd-openvas.service
Wants=postgresql.service ospd-openvas.service
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
"
mkunit "gsad" "[Unit]
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
ExecStart=/usr/local/sbin/gsad --foreground --listen=127.0.0.1 --port=9392 --http-only
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
"
mkunit "openvasd" "[Unit]
Description=OpenVASD
[Service]
Type=exec
User=gvm
RuntimeDirectory=openvasd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/bin/openvasd --mode service_notus --products /var/lib/notus/products --advisories /var/lib/notus/advisories --listening 127.0.0.1:3000
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
"
maybe_sudo systemctl daemon-reload

# ---------------- Feed sync (as gvm) ----------------
log "Feed sync prep (ownership & locks)"
maybe_sudo install -o gvm -g gvm -m 0660 /dev/null /var/lib/gvm/feed-update.lock || true
maybe_sudo install -o gvm -g gvm -m 0660 /dev/null /var/lib/openvas/feed-update.lock || true

if (( SKIP_FEED )); then
  wrn "Skipping initial feed sync"
else
  log "Installing greenbone-feed-sync & running as gvm (first sync may take long)"
  python3 -m pip install --user --upgrade greenbone-feed-sync || true
  BIN="$(python3 -m site --user-base)/bin/greenbone-feed-sync"
  if [[ -x "$BIN" ]]; then
    maybe_sudo -u gvm -g gvm "$BIN"
  elif command -v greenbone-feed-sync >/dev/null 2>&1; then
    maybe_sudo -u gvm -g gvm greenbone-feed-sync
  else
    wrn "greenbone-feed-sync not found; install manually then rerun."
  fi
fi

# ---------------- Start services ----------------
log "Start services"
maybe_sudo systemctl enable ospd-openvas gvmd gsad openvasd --now || true
log "DONE 🎉  Open GSA: http://127.0.0.1:${PORT}/   user=${GVM_ADMIN_USER}   pass=${GVM_ADMIN_PASS}"
