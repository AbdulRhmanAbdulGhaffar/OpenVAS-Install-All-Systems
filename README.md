# OpenVAS Cross‑Platform Setup (Bash Installer)

<p align="center">
  <a href="#overview"><img alt="OpenVAS" src="https://img.shields.io/badge/OpenVAS-GVM-green" /></a>
  <a href="https://github.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/actions"><img alt="CI" src="https://github.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/actions/workflows/ci.yml/badge.svg" /></a>
  <a href="#supported-environments"><img alt="OS" src="https://img.shields.io/badge/OS-Linux%20%7C%20WSL%20%7C%20macOS-lightgrey" /></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-yellow" /></a>
</p>

> **One script, multiple systems.** Production‑quality **Bash installer** + step‑by‑step guides for **Linux**, **Windows (WSL2)**, and **macOS (Docker)**. Each platform has its own section & quick‑links.

---

## Table of Contents
- [Overview](#overview)
- [Hardware Requirements](#hardware-requirements)
- [Supported Environments](#supported-environments)
- [Per‑OS One‑Liners](#per-os-one-liners)
- [Quick Start](#quick-start)
- [Script Usage](#script-usage)
- [Environment Variables](#environment-variables)
- [Linux — Build from Source](#linux--build-from-source)
  - [1) Create gvm User/Group](#1-create-gvm-usergroup)
  - [2) Set Environment Variables](#2-set-environment-variables)
  - [3) Install Common Build Dependencies](#3-install-common-build-dependencies)
  - [4) Import Greenbone Signing Key](#4-import-greenbone-signing-key)
  - [5) Build and Install Components](#5-build-and-install-components)
  - [6) System Setup (Redis, Permissions, sudo)](#6-system-setup-redis-permissions-sudo)
  - [7) PostgreSQL Setup](#7-postgresql-setup)
  - [8) Create Admin & Feed Owner](#8-create-admin--feed-owner)
  - [9) Systemd Services](#9-systemd-services)
  - [10) Feed Sync & First Start](#10-feed-sync--first-start)
- [Windows — WSL2 Guide](#windows--wsl2-guide)
- [macOS — Docker Compose Stack](#macos--docker-compose-stack)
- [Verification](#verification)
- [Common Issues](#common-issues)
- [Uninstall / Cleanup](#uninstall--cleanup)
- [Security Notes](#security-notes)
- [Repository Structure](#repository-structure)
- [Contributing](#contributing)
- [License](#license)
- [🇸🇦 ملخص بالعربي](#-ملخص-بالعربي)

---

## Overview
Ships a **single Bash script** that detects your platform and installs/configures OpenVAS (GVM) with sensible defaults. Includes **Docker** & **WSL** paths where native packages are limited.

**Goals**
- Minimal user interaction (non‑interactive supported)
- Idempotent & reproducible
- Clear logs and rollback path

---

## Hardware Requirements
**Minimal:** 2 CPU, 4 GB RAM, 20 GB disk  
**Recommended:** 4 CPU, 8 GB RAM, 60 GB disk

---

## Supported Environments
- **Linux (native):** Debian 12, Ubuntu 24.04 LTS, Fedora 38, CentOS 9 Stream *(other Debian derivatives like Mint/Kali likely work with minor tweaks)*
- **Windows:** Windows 10/11 via **WSL2 (Ubuntu)**
- **macOS:** via **Docker**

---

## Per‑OS One‑Liners
### Linux (Debian/Ubuntu/Fedora/Arch)
```bash
curl -fsSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/main/openvas-install.sh \
| bash -s -- --yes
```
Examples:
```bash
# Faster first run: skip feed sync
curl -fsSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/main/openvas-install.sh \
| bash -s -- --skip-feed-sync --yes

# Custom web UI port
curl -fsSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/main/openvas-install.sh \
| bash -s -- --port 9443 --yes
```

### macOS (Docker recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/main/openvas-install.sh \
| bash -s -- --use-docker --yes
```

### Windows 10/11 (WSL2)
```powershell
# Run in PowerShell (Admin the first time to install WSL)
wsl --install -d Ubuntu
# After reboot (if asked):
wsl -e bash -lc "curl -fsSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/main/openvas-install.sh | bash -s -- --wsl --yes"
```

---

## Quick Start
```bash
git clone https://github.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems.git
cd OpenVAS-Install-All-Systems
chmod +x openvas-install.sh
./openvas-install.sh --yes
```

## Script Usage
```text
Usage: openvas-install.sh [OPTIONS]
  --os <id>            ubuntu|debian|kali|fedora|centos|rhel|rocky|alma|arch|macos|generic
  --use-docker         Use Docker compose stack (recommended on macOS)
  --wsl                Optimize for WSL2 (Windows)
  --port <number>      Web UI port (default: 9392)
  --with-postgres      Install/initialize PostgreSQL (default)
  --no-postgres        Skip local PostgreSQL installation
  --no-sudo            Run without sudo
  --skip-feed-sync     Skip initial feed sync
  --yes, -y            Non-interactive mode
  --reset              Recreate admin & restart services
  --uninstall          Remove components and data
  --verbose            Print extra logs
  -h, --help           Show this help and exit
```

## Environment Variables
```bash
export GVM_ADMIN_USER=admin
export GVM_ADMIN_PASS='StrongPassword!'
export GVM_LISTEN_ADDR=0.0.0.0
export GVM_PORT=9392
```

---

## Linux — Build from Source
> Full, signed build steps with versions pinned. Prefer **Ubuntu 24.04 / Debian 12**.
*(Full commands automated inside the script; README mirrors them for transparency.)*

### 1) Create gvm User/Group
```bash
sudo useradd -r -M -U -G sudo -s /usr/sbin/nologin gvm
sudo usermod -aG gvm $USER
```

### 2) Set Environment Variables
```bash
export INSTALL_PREFIX=/usr/local
export PATH=$PATH:$INSTALL_PREFIX/sbin
export SOURCE_DIR=$HOME/source && mkdir -p $SOURCE_DIR
export BUILD_DIR=$HOME/build && mkdir -p $BUILD_DIR
export INSTALL_DIR=$HOME/install && mkdir -p $INSTALL_DIR
```

### 3) Install Common Build Dependencies (Debian/Ubuntu)
```bash
sudo apt update
sudo apt install --no-install-recommends --assume-yes \
  build-essential curl cmake pkg-config python3 python3-pip gnupg
```

### 4) Import Greenbone Signing Key
```bash
curl -f -L https://www.greenbone.net/GBCommunitySigningKey.asc -o /tmp/GBCommunitySigningKey.asc
gpg --import /tmp/GBCommunitySigningKey.asc
echo "8AE4BE429B60A59B311C2E739823FAA60ED1E580:6:" | gpg --import-ownertrust
```

### 5) Build and Install Components
> Order: **gvm-libs → gvmd → pg-gvm → GSA → gsad → openvas-smb (optional) → openvas-scanner → ospd-openvas → openvasd**

### 6) System Setup (Redis, Permissions, sudo)
```bash
sudo apt install -y redis-server
# + redis socket, openvas.conf, user groups (automated by script)
```

### 7) PostgreSQL Setup
```bash
sudo apt install -y postgresql
sudo systemctl start postgresql@15-main || true
sudo -u postgres bash -c 'createuser -DRS gvm; createdb -O gvm gvmd; psql gvmd -c "create role dba with superuser noinherit; grant dba to gvm;"'
```

### 8) Create Admin & Feed Owner
```bash
/usr/local/sbin/gvmd --create-user=admin --password='ChangeMe!'
/usr/local/sbin/gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value `/usr/local/sbin/gvmd --get-users --verbose | grep admin | awk '{print $2}'`
```

### 9) Systemd Services
*(Service unit files are installed by the script.)*

### 10) Feed Sync & First Start
```bash
sudo /usr/local/bin/greenbone-feed-sync
sudo systemctl start ospd-openvas gvmd gsad openvasd
sudo systemctl enable ospd-openvas gvmd gsad openvasd
```

---

## Windows — WSL2 Guide
See **Per‑OS One‑Liners** above.

---

## macOS — Docker Compose Stack
See **Per‑OS One‑Liners** above.

---

## Verification
```bash
systemctl status gvmd gsad ospd-openvas openvasd
journalctl -u gvmd -e --no-pager
journalctl -u gsad -e --no-pager
```

---

## Common Issues
See: [`docs/troubleshooting.md`](docs/troubleshooting.md)

---

## Uninstall / Cleanup
- Native: `./openvas-install.sh --uninstall`
- Docker: `docker compose down -v`

---

## Security Notes
- Strong credentials, restricted exposure, and up‑to‑date feeds/packages.

---

## Repository Structure
```
.
├─ openvas-install.sh
├─ docker/
│  ├─ docker-compose.yml
│  └─ .env.example
├─ docs/
│  ├─ troubleshooting.md
│  ├─ verification.md
│  └─ uninstall.md
├─ .github/
│  ├─ workflows/ci.yml
│  ├─ ISSUE_TEMPLATE/
│  │  ├─ bug_report.md
│  │  └─ feature_request.md
│  └─ PULL_REQUEST_TEMPLATE.md
├─ CONTRIBUTING.md
├─ CODE_OF_CONDUCT.md
├─ SECURITY.md
├─ CHANGELOG.md
├─ .editorconfig
├─ .gitattributes
└─ LICENSE
```

---

## 🇸🇦 ملخص بالعربي
- سكربت واحد يشتغل على كل الأنظمة مع one‑liner جاهز.  
- Docker للماك، WSL للوِيندوز، وبناء كامل للسورس للينكس.  
- CI، وثائق، قوالب Issues/PRs، وملفات جودة المشروع مضافة.
# OpenVAS-Install-All-Systems
