#!/usr/bin/env bash
# ==============================================================================
# OpenVAS / Greenbone Community Edition — Universal Installer (fixed)
# - fixes: GSA extract path, ospd-openvas apt/pip conflict, gssapi missing (libkrb5-dev),
#   writable SOURCE_DIR (avoid /root/source write errors), systemd units, feed sync.
# Repository: https://github.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems
# Author: Adapted for you
# License: MIT
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ---------- Config / defaults ----------
OS_ID=""; USE_DOCKER=0; IS_WSL=0; PORT=9392; WITH_POSTGRES=1; NO_SUDO=0
SKIP_FEED=0; NONINTERACTIVE=0; VERBOSE=0; RESET=0; UNINSTALL=0

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
GVM_ADMIN_USER="${GVM_ADMIN_USER:-admin}"
GVM_ADMIN_PASS="${GVM_ADMIN_PASS:-ChangeMe!2025}"
GVM_LISTEN_ADDR="${GVM_LISTEN_ADDR:-0.0.0.0}"

GVM_LIBS_VERSION="${GVM_LIBS_VERSION:-22.22.0}"
GVMD_VERSION="${GVMD_VERSION:-26.0.0}"
PG_GVM_VERSION="${PG_GVM_VERSION:-22.6.9}"
GSA_VERSION="${GSA_VERSION:-25.0.0}"
GSAD_VERSION="${GSAD_VERSION:-24.3.0}"
OPENVAS_SMB_VERSION="${OPENVAS_SMB_VERSION:-22.5.3}"
OPENVAS_SCANNER_VERSION="${OPENVAS_SCANNER_VERSION:-23.20.1}"
OSPD_OPENVAS_VERSION="${OSPD_OPENVAS_VERSION:-22.9.0}"
OPENVAS_DAEMON="${OPENVAS_DAEMON:-23.20.0}"

# Use HOME-based working dirs by default to avoid /root write failures
SOURCE_DIR="${SOURCE_DIR:-$HOME/source}"
BUILD_DIR="${BUILD_DIR:-$HOME/build}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/install}"
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"

# ---------- helpers ----------
log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
wrn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
err(){ printf "\033[1;31m[x] \033[0m%s\n" "$*"; } >&2
run(){ if (( VERBOSE )); then set -x; fi; "$@"; if (( VERBOSE )); then set +x; fi; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }
maybe_sudo(){ if (( NO_SUDO )); then "$@"; else sudo "$@"; fi }

usage(){ cat <<EOF
Usage: $0 [OPTIONS]
  --os <id>            ubuntu|debian|kali|fedora|centos|rhel|rocky|alma|arch|macos|generic
  --use-docker         Use Docker Compose stack (recommended on macOS)
  --wsl                Optimize for WSL2 (Windows)
  --port <number>      Web UI port (default: 9392)
  --no-postgres        Skip local PostgreSQL installation
  --no-sudo            Do not use sudo (run as root)
  --skip-feed-sync     Skip initial feed sync
  --yes, -y            Non-interactive mode
  --reset              Reconfigure admin and restart services
  --uninstall          Remove installed components and data
  --verbose            Verbose output
  -h, --help           Show this help and exit
EOF
}

while (( $# )); do case "$1" in
  --os) OS_ID="$2"; shift;;
  --use-docker) USE_DOCKER=1;;
  --wsl) IS_WSL=1;;
  --port) PORT="$2"; shift;;
  --no-postgres) WITH_POSTGRES=0;;
  --no-sudo) NO_SUDO=1;;
  --skip-feed-sync) SKIP_FEED=1;;
  --yes|-y) NONINTERACTIVE=1;;
  --reset) RESET=1;;
  --uninstall) UNINSTALL=1;;
  --verbose) VERBOSE=1;;
  -h|--help) usage; exit 0;;
  *) err "Unknown option: $1"; usage; exit 2;;
esac; shift; done

# Detect OS if not provided
if [[ -z "$OS_ID" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then OS_ID="macos"; fi
  if [[ -z "${OS_ID}" && -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-generic}"; fi
  if [[ -z "${OS_ID}" ]]; then OS_ID="generic"; fi
  if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; [[ "$OS_ID" == generic ]] && OS_ID="ubuntu"; fi
fi

# ---------- Uninstall mode ----------
if (( UNINSTALL )); then
  wrn "Uninstalling OpenVAS (stopping services and removing files)..."
  set +e
  maybe_sudo systemctl stop gvmd gsad ospd-openvas openvasd 2>/dev/null || true
  maybe_sudo systemctl disable gvmd gsad ospd-openvas openvasd 2>/dev/null || true
  maybe_sudo rm -f /etc/systemd/system/{gvmd,gsad,ospd-openvas,openvasd}.service || true
  maybe_sudo systemctl daemon-reload || true
  maybe_sudo rm -rf /var/lib/{gvm,openvas,notus} /var/log/gvm /etc/openvas /run/gvmd || true
  maybe_sudo userdel gvm 2>/dev/null || true
  maybe_sudo groupdel gvm 2>/dev/null || true
  set -e
  log "Uninstall finished."
  exit 0
fi

# ---------- Docker path (macOS-friendly) ----------
if [[ "$OS_ID" == "macos" || "$USE_DOCKER" -eq 1 ]]; then
  log "Using Docker Compose deployment (good for macOS)."
  need docker
  mkdir -p docker
  cat > docker/docker-compose.yml <<YAML
version: "3.9"
services:
  gvmd:
    image: greenbone/gvmd:stable
    container_name: gvmd
    env_file: .env
    volumes:
      - gvm-data:/var/lib/gvm
      - gvm-log:/var/log/gvm
    ports:
      - "${PORT}:${PORT}"
    depends_on:
      - openvasd
      - ospd
  ospd:
    image: greenbone/ospd-openvas:stable
    container_name: ospd-openvas
    volumes:
      - gvm-data:/var/lib/gvm
      - openvas-data:/var/lib/openvas
      - notus:/var/lib/notus
  openvasd:
    image: greenbone/openvasd:stable
    container_name: openvasd
    volumes:
      - notus:/var/lib/notus
  feed-sync:
    image: greenbone/greenbone-feed-sync:stable
    container_name: greenbone-feed-sync
    volumes:
      - gvm-data:/var/lib/gvm
      - openvas-data:/var/lib/openvas
      - notus:/var/lib/notus
volumes:
  gvm-data: {}
  gvm-log: {}
  openvas-data: {}
  notus: {}
YAML
  cat > docker/.env <<ENV
GVM_ADMIN_USER=${GVM_ADMIN_USER}
GVM_ADMIN_PASS=${GVM_ADMIN_PASS}
GVM_PORT=${PORT}
ENV
  (cd docker && docker compose up -d)
  log "Docker stack started — open: https://localhost:${PORT}/"
  exit 0
fi

# ---------- Linux native path ----------
log "Native Linux build path: $OS_ID"

if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt update
  run sudo apt install --no-install-recommends --assume-yes \
    build-essential curl cmake pkg-config python3 python3-pip gnupg ca-certificates \
    rsync git wget pkg-config
elif [[ "$OS_ID" =~ fedora|rhel|rocky|alma|centos ]]; then
  run sudo dnf -y install @"Development Tools" curl cmake pkgconf-pkg-config python3 python3-pip gnupg2 rsync git wget
elif [[ "$OS_ID" == "arch" ]]; then
  run sudo pacman -Syu --noconfirm base-devel curl cmake python gnupg rsync git wget
else
  wrn "Generic OS — adjust dependencies manually if needed."
fi

export PATH="$PATH:$INSTALL_PREFIX/sbin"

# GPG key for feed verification
if ! gpg -k 8AE4BE429B60A59B311C2E739823FAA60ED1E580 >/dev/null 2>&1; then
  run curl -fsSL https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
  run gpg --import /tmp/GBCommunitySigningKey.asc || true
  run bash -c "echo '8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:' | gpg --import-ownertrust" || true
fi

# Create gvm user/group and directories
if ! id -u gvm >/dev/null 2>&1; then
  maybe_sudo useradd -r -M -U -s /usr/sbin/nologin gvm || true
fi
maybe_sudo usermod -aG gvm "$USER" || true
maybe_sudo mkdir -p /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd /etc/openvas
maybe_sudo chown -R gvm:gvm /var/lib/{gvm,openvas,notus} /var/log/gvm /run/gvmd
maybe_sudo chmod -R g+srw /var/lib/{gvm,openvas} /var/log/gvm

# Redis & Postgres install
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y redis-server
  if (( WITH_POSTGRES )); then run sudo apt install -y postgresql postgresql-server-dev-all; fi
elif [[ "$OS_ID" =~ fedora|rhel|rocky|alma|centos ]]; then
  run sudo dnf -y install redis
  if (( WITH_POSTGRES )); then run sudo dnf -y install postgresql-server postgresql-devel; fi
fi

# helper functions for fetch/build
fetch_and_verify(){ # url_tar url_sig out_tar
  local tar="$3" sig="$3.asc"
  run curl -f -L "$1" -o "$tar"
  run curl -f -L "$2" -o "$sig"
  run gpg --verify "$sig" "$tar"
}
extract_to(){ # tarfile, targetdir
  local tarfile="$1" target="$2"
  mkdir -p "$target"
  tar -C "$target" -xvzf "$tarfile"
}

# ---------------- gvm-libs ----------------
log "Building gvm-libs $GVM_LIBS_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y libcjson-dev libcurl4-gnutls-dev libgcrypt-dev libglib2.0-dev \
    libgnutls28-dev libgpgme-dev libhiredis-dev libnet1-dev libpaho-mqtt-dev \
    libpcap-dev libssh-dev libxml2-dev uuid-dev libldap2-dev libradcli-dev
fi
tarball="$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/gvm-libs/archive/refs/tags/v$GVM_LIBS_VERSION.tar.gz" \
  "https://github.com/greenbone/gvm-libs/releases/download/v$GVM_LIBS_VERSION/gvm-libs-$GVM_LIBS_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION"
run cmake -S "$SOURCE_DIR/gvm-libs-$GVM_LIBS_VERSION" -B "$BUILD_DIR/gvm-libs" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var
run cmake --build "$BUILD_DIR/gvm-libs" -j"$(nproc)"
run mkdir -p "$INSTALL_DIR/gvm-libs" && cd "$BUILD_DIR/gvm-libs"
run make DESTDIR="$INSTALL_DIR/gvm-libs" install
maybe_sudo cp -rv "$INSTALL_DIR/gvm-libs"/* /

# ---------------- gvmd ----------------
log "Building gvmd $GVMD_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y libbsd-dev libcjson-dev libglib2.0-dev libgnutls28-dev libgpgme-dev \
    libical-dev libpq-dev rsync xsltproc
fi
tarball="$SOURCE_DIR/gvmd-$GVMD_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/gvmd/archive/refs/tags/v$GVMD_VERSION.tar.gz" \
  "https://github.com/greenbone/gvmd/releases/download/v$GVMD_VERSION/gvmd-$GVMD_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/gvmd-$GVMD_VERSION"
run cmake -S "$SOURCE_DIR/gvmd-$GVMD_VERSION" -B "$BUILD_DIR/gvmd" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DLOCALSTATEDIR=/var -DSYSCONFDIR=/etc -DGVM_DATA_DIR=/var \
  -DGVM_LOG_DIR=/var/log/gvm -DGVMD_RUN_DIR=/run/gvmd \
  -DOPENVAS_DEFAULT_SOCKET=/run/ospd/ospd-openvas.sock \
  -DGVM_FEED_LOCK_PATH=/var/lib/gvm/feed-update.lock -DLOGROTATE_DIR=/etc/logrotate.d
run cmake --build "$BUILD_DIR/gvmd" -j"$(nproc)"
run mkdir -p "$INSTALL_DIR/gvmd" && cd "$BUILD_DIR/gvmd"
run make DESTDIR="$INSTALL_DIR/gvmd" install
maybe_sudo cp -rv "$INSTALL_DIR/gvmd"/* /

# ---------------- pg-gvm ----------------
log "Building pg-gvm $PG_GVM_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y libglib2.0-dev libical-dev postgresql-server-dev-all
fi
tarball="$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/pg-gvm/archive/refs/tags/v$PG_GVM_VERSION.tar.gz" \
  "https://github.com/greenbone/pg-gvm/releases/download/v$PG_GVM_VERSION/pg-gvm-$PG_GVM_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION"
run cmake -S "$SOURCE_DIR/pg-gvm-$PG_GVM_VERSION" -B "$BUILD_DIR/pg-gvm" -DCMAKE_BUILD_TYPE=Release
run cmake --build "$BUILD_DIR/pg-gvm" -j"$(nproc)"
run mkdir -p "$INSTALL_DIR/pg-gvm" && cd "$BUILD_DIR/pg-gvm"
run make DESTDIR="$INSTALL_DIR/pg-gvm" install
maybe_sudo cp -rv "$INSTALL_DIR/pg-gvm"/* /

# ---------------- GSA (dist) ----------------
log "Installing GSA dist $GSA_VERSION (prebuilt web frontend)"
tarball="$SOURCE_DIR/gsa-$GSA_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz" \
  "https://github.com/greenbone/gsa/releases/download/v$GSA_VERSION/gsa-dist-$GSA_VERSION.tar.gz.asc" \
  "$tarball"
# extract into dedicated folder to avoid missing-file cp
extract_to "$tarball" "$SOURCE_DIR/gsa-$GSA_VERSION"
maybe_sudo mkdir -p "$INSTALL_PREFIX/share/gvm/gsad/web/"
maybe_sudo cp -rv "$SOURCE_DIR/gsa-$GSA_VERSION"/* "$INSTALL_PREFIX/share/gvm/gsad/web/"

# ---------------- gsad (web server) ----------------
log "Building gsad $GSAD_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y libbrotli-dev libglib2.0-dev libgnutls28-dev libmicrohttpd-dev libxml2-dev
fi
tarball="$SOURCE_DIR/gsad-$GSAD_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/gsad/archive/refs/tags/v$GSAD_VERSION.tar.gz" \
  "https://github.com/greenbone/gsad/releases/download/v$GSAD_VERSION/gsad-$GSAD_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/gsad-$GSAD_VERSION"
run cmake -S "$SOURCE_DIR/gsad-$GSAD_VERSION" -B "$BUILD_DIR/gsad" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var -DGVMD_RUN_DIR=/run/gvmd \
  -DGSAD_RUN_DIR=/run/gsad -DGVM_LOG_DIR=/var/log/gvm -DLOGROTATE_DIR=/etc/logrotate.d
run cmake --build "$BUILD_DIR/gsad" -j"$(nproc)"
run mkdir -p "$INSTALL_DIR/gsad" && cd "$BUILD_DIR/gsad"
run make DESTDIR="$INSTALL_DIR/gsad" install
maybe_sudo cp -rv "$INSTALL_DIR/gsad"/* /

# ---------------- openvas-smb (optional) ----------------
log "Building openvas-smb $OPENVAS_SMB_VERSION (optional)"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y gcc-mingw-w64 libgnutls28-dev libglib2.0-dev libpopt-dev libunistring-dev heimdal-multidev perl-base
fi
tarball="$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/openvas-smb/archive/refs/tags/v$OPENVAS_SMB_VERSION.tar.gz" \
  "https://github.com/greenbone/openvas-smb/releases/download/v$OPENVAS_SMB_VERSION/openvas-smb-v$OPENVAS_SMB_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION"
run cmake -S "$SOURCE_DIR/openvas-smb-$OPENVAS_SMB_VERSION" -B "$BUILD_DIR/openvas-smb" -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release
run cmake --build "$BUILD_DIR/openvas-smb" -j"$(nproc)" || wrn "openvas-smb build issue (optional)"
run mkdir -p "$INSTALL_DIR/openvas-smb" && cd "$BUILD_DIR/openvas-smb"
run make DESTDIR="$INSTALL_DIR/openvas-smb" install || wrn "openvas-smb install issue"
maybe_sudo cp -rv "$INSTALL_DIR/openvas-smb"/* / || wrn "openvas-smb step skipped/failed (optional)."

# ---------------- openvas-scanner (scanner) ----------------
log "Building openvas-scanner $OPENVAS_SCANNER_VERSION"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y bison libglib2.0-dev libgnutls28-dev libgcrypt20-dev libpcap-dev \
    libgpgme-dev libksba-dev rsync nmap libjson-glib-dev libcurl4-gnutls-dev \
    libbsd-dev libkrb5-dev python3-impacket libsnmp-dev doxygen pandoc || true
fi
tarball="$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_SCANNER_VERSION.tar.gz" \
  "https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_SCANNER_VERSION/openvas-scanner-v$OPENVAS_SCANNER_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION"
# build
run cmake -S "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION" -B "$BUILD_DIR/openvas-scanner" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DSYSCONFDIR=/etc -DLOCALSTATEDIR=/var \
  -DOPENVAS_FEED_LOCK_PATH=/var/lib/openvas/feed-update.lock -DOPENVAS_RUN_DIR=/run/ospd
run cmake --build "$BUILD_DIR/openvas-scanner" -j"$(nproc)" || { err "openvas-scanner build failed"; exit 1; }
run mkdir -p "$INSTALL_DIR/openvas-scanner" && cd "$BUILD_DIR/openvas-scanner"
run make DESTDIR="$INSTALL_DIR/openvas-scanner" install
maybe_sudo cp -rv "$INSTALL_DIR/openvas-scanner"/* /
# set scanner conf
maybe_sudo mkdir -p /etc/openvas || true
echo "table_driven_lsc = yes" | maybe_sudo tee /etc/openvas/openvas.conf >/dev/null || true
echo "openvasd_server = http://127.0.0.1:3000" | maybe_sudo tee -a /etc/openvas/openvas.conf >/dev/null || true

# ---------------- ospd-openvas ----------------
log "Installing ospd-openvas $OSPD_OPENVAS_VERSION (fixed flow)"
# Remove Debian packaged version (if present) to avoid pip uninstall errors
if dpkg -s python3-ospd-openvas >/dev/null 2>&1; then
  wrn "Removing Debian package python3-ospd-openvas to avoid conflicts"
  run sudo apt remove -y python3-ospd-openvas || true
fi
# ensure python deps
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  run sudo apt install -y python3 python3-pip python3-setuptools python3-packaging python3-wrapt \
    python3-cffi python3-psutil python3-lxml python3-defusedxml python3-paramiko \
    python3-redis python3-gnupg python3-paho-mqtt
fi
tarball="$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/ospd-openvas/archive/refs/tags/v$OSPD_OPENVAS_VERSION.tar.gz" \
  "https://github.com/greenbone/ospd-openvas/releases/download/v$OSPD_OPENVAS_VERSION/ospd-openvas-v$OSPD_OPENVAS_VERSION.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
mkdir -p "$INSTALL_DIR/ospd-openvas"
cd "$SOURCE_DIR/ospd-openvas-$OSPD_OPENVAS_VERSION"
# install via pip but avoid pip trying to uninstall apt-managed packages:
run python3 -m pip install --no-deps --root="$INSTALL_DIR/ospd-openvas" --no-warn-script-location .
maybe_sudo cp -rv "$INSTALL_DIR/ospd-openvas"/* /

# ---------------- openvasd (Rust) ----------------
log "Building openvasd (rust) $OPENVAS_DAEMON"
if [[ "$OS_ID" =~ ubuntu|debian|kali ]]; then
  if ! command -v cargo >/dev/null 2>&1; then
    run curl https://sh.rustup.rs -sSf | sh -s -- -y
    source "$HOME/.cargo/env"
  fi
  run sudo apt install -y pkg-config libssl-dev
  run rustup update stable || true
fi
tarball="$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON.tar.gz"
fetch_and_verify \
  "https://github.com/greenbone/openvas-scanner/archive/refs/tags/v$OPENVAS_DAEMON.tar.gz" \
  "https://github.com/greenbone/openvas-scanner/releases/download/v$OPENVAS_DAEMON/openvas-scanner-v$OPENVAS_DAEMON.tar.gz.asc" \
  "$tarball"
extract_to "$tarball" "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON"
mkdir -p "$INSTALL_DIR/openvasd/usr/local/bin"
( cd "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust/src/openvasd" && run cargo build --release )
( cd "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/rust/src/scannerctl" && run cargo build --release )
maybe_sudo cp -v "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/target/release/openvasd" "$INSTALL_DIR/openvasd/usr/local/bin/" || true
maybe_sudo cp -v "$SOURCE_DIR/openvas-scanner-$OPENVAS_DAEMON/target/release/scannerctl" "$INSTALL_DIR/openvasd/usr/local/bin/" || true
maybe_sudo cp -rv "$INSTALL_DIR/openvasd"/* / || true

# ---------------- Redis config ----------------
log "Configuring Redis for OpenVAS"
if [[ -f "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" ]]; then
  maybe_sudo cp "$SOURCE_DIR/openvas-scanner-$OPENVAS_SCANNER_VERSION/config/redis-openvas.conf" /etc/redis/ || true
  maybe_sudo chown redis:redis /etc/redis/redis-openvas.conf || true
  echo "db_address = /run/redis-openvas/redis.sock" | maybe_sudo tee -a /etc/openvas/openvas.conf >/dev/null || true
  maybe_sudo systemctl start redis-server@openvas.service || true
  maybe_sudo systemctl enable redis-server@openvas.service || true
  maybe_sudo usermod -aG redis gvm || true
else
  wrn "redis-openvas.conf not found yet; ensure openvas-scanner sources downloaded."
fi

# ---------------- Permissions & sudoers ----------------
log "Fixing permissions and sudoers"
maybe_sudo mkdir -p /var/lib/notus /run/gvmd || true
maybe_sudo chown -R gvm:gvm /var/lib/gvm /var/lib/openvas /var/lib/notus /var/log/gvm /run/gvmd || true
maybe_sudo chmod -R g+srw /var/lib/gvm /var/lib/openvas /var/log/gvm || true
if [[ -x "$INSTALL_PREFIX/sbin/gvmd" ]]; then
  maybe_sudo chown gvm:gvm "$INSTALL_PREFIX/sbin/gvmd" || true
  maybe_sudo chmod 6750 "$INSTALL_PREFIX/sbin/gvmd" || true
fi
echo "%gvm ALL = NOPASSWD: $INSTALL_PREFIX/sbin/openvas" | maybe_sudo tee /etc/sudoers.dumps >/dev/null || true
maybe_sudo install -m 0440 /etc/sudoers.dumps /etc/sudoers.d/gvm || true
maybe_sudo rm -f /etc/sudoers.dumps || true

# ---------------- PostgreSQL setup ----------------
if (( WITH_POSTGRES )); then
  log "Setting up PostgreSQL (creating gvm user and gvmd DB)"
  run sudo systemctl start postgresql || true
  run sudo -u postgres bash -c 'createuser -DRS gvm 2>/dev/null || true; createdb -O gvm gvmd 2>/dev/null || true; psql gvmd -c "create role dba with superuser noinherit; grant dba to gvm;" >/dev/null 2>&1 || true'
fi

# ---------------- Feed GPG keyring ----------------
log "Preparing GPG keyring for feed validation"
export GNUPGHOME=/tmp/openvas-gnupg
mkdir -p "$GNUPGHOME"
run curl -fsSL https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc || true
run gpg --import /tmp/GBCommunitySigningKey.asc || true
run bash -c "echo '8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:' | gpg --import-ownertrust" || true
export OPENVAS_GNUPG_HOME=/etc/openvas/gnupg
maybe_sudo mkdir -p "$OPENVAS_GNUPG_HOME"
maybe_sudo cp -r "$GNUPGHOME"/* "$OPENVAS_GNUPG_HOME"/ || true
maybe_sudo chown -R gvm:gvm "$OPENVAS_GNUPG_HOME" || true

# ---------------- Admin user & feed import owner ----------------
log "Creating admin user and setting Feed Import Owner (if gvmd available)"
if [[ -x "$INSTALL_PREFIX/sbin/gvmd" ]]; then
  maybe_sudo "$INSTALL_PREFIX/sbin/gvmd" --create-user="$GVM_ADMIN_USER" --password="$GVM_ADMIN_PASS" || true
  owner=$($INSTALL_PREFIX/sbin/gvmd --get-users --verbose | grep " $GVM_ADMIN_USER " | awk '{print $2}') || owner=""
  if [[ -n "$owner" ]]; then
    maybe_sudo "$INSTALL_PREFIX/sbin/gvmd" --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$owner" || true
  fi
fi

# ---------------- systemd units ----------------
log "Installing systemd service files"
cat > "$BUILD_DIR/ospd-openvas.service" <<'EOF'
[Unit]
Description=OSPd Wrapper for the OpenVAS Scanner (ospd-openvas)
After=network.target networking.service redis-server@openvas.service openvasd.service
Wants=redis-server@openvas.service openvasd.service
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
Group=gvm
RuntimeDirectory=ospd
RuntimeDirectoryMode=2775
PIDFile=/run/ospd/ospd-openvas.pid
ExecStart=/usr/local/bin/ospd-openvas --foreground --unix-socket /run/ospd/ospd-openvas.sock --pid-file /run/ospd/ospd-openvas.pid --log-file /var/log/gvm/ospd-openvas.log --lock-file-dir /var/lib/openvas --socket-mode 0o770 --notus-feed-dir /var/lib/notus/advisories
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF

cat > "$BUILD_DIR/gvmd.service" <<'EOF'
[Unit]
Description=Greenbone Vulnerability Manager daemon (gvmd)
After=network.target networking.service postgresql.service ospd-openvas.service
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

cat > "$BUILD_DIR/gsad.service" <<'EOF'
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
ExecStart=/usr/local/sbin/gsad --foreground --listen=127.0.0.1 --port=9392 --http-only
Restart=always
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
Alias=greenbone-security-assistant.service
EOF

cat > "$BUILD_DIR/openvasd.service" <<'EOF'
[Unit]
Description=OpenVASD
ConditionKernelCommandLine=!recovery
[Service]
Type=exec
User=gvm
RuntimeDirectory=openvasd
RuntimeDirectoryMode=2775
ExecStart=/usr/local/bin/openvasd --mode service_notus --products /var/lib/notus/products --advisories /var/lib/notus/advisories --listening 127.0.0.1:3000
SuccessExitStatus=SIGKILL
Restart=always
RestartSec=60
[Install]
WantedBy=multi-user.target
EOF

maybe_sudo cp -v "$BUILD_DIR"/{gvmd.service,gsad.service,ospd-openvas.service,openvasd.service} /etc/systemd/system/ || true
maybe_sudo systemctl daemon-reload || true

# ---------------- Feed sync (greenbone-feed-sync) ----------------
if (( SKIP_FEED )); then
  wrn "Skipping feed sync by request"
else
  log "Installing greenbone-feed-sync and performing initial sync (can take long)"
  python3 -m pip install --user --upgrade greenbone-feed-sync || true
  BIN="$(python3 -m site --user-base)/bin/greenbone-feed-sync"
  if [[ -x "$BIN" ]]; then maybe_sudo "$BIN"; elif command -v greenbone-feed-sync >/dev/null 2>&1; then maybe_sudo greenbone-feed-sync; else wrn "Install greenbone-feed-sync manually."; fi
fi

# ---------------- Start services ----------------
log "Starting services (ospd-openvas, gvmd, gsad, openvasd)"
maybe_sudo systemctl start ospd-openvas gvmd gsad openvasd || true
maybe_sudo systemctl enable ospd-openvas gvmd gsad openvasd || true

log "Finished. Access UI at: https://127.0.0.1:${PORT}/ (user: ${GVM_ADMIN_USER})"
