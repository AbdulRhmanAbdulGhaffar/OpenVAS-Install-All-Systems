#!/usr/bin/env bash
# ==============================================================================
# OpenVAS / Greenbone Community Edition — Cross-Platform Installer (Full Source)
# Repository: https://github.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems
# Author: AbdulRhman AbdulGhaffar
# License: MIT
# ==============================================================================
set -euo pipefail

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

# Ensure writable working dirs (works for root/non-root)
SOURCE_DIR="${SOURCE_DIR:-$HOME/source}"
BUILD_DIR="${BUILD_DIR:-$HOME/build}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/install}"
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR"

log(){ printf "\033[1;32m[+] \033[0m%s\n" "$*"; }
wrn(){ printf "\033[1;33m[!] \033[0m%s\n" "$*"; }
err(){
