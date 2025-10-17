SHELL := /usr/bin/env bash

.PHONY: all linux docker wsl feed logs uninstall reset lint

all: linux

linux:
	./openvas-install.sh --yes

docker:
	./openvas-install.sh --use-docker --yes

wsl:
	pwsh -NoLogo -NoProfile -Command "wsl -e bash -lc 'curl -fsSL https://raw.githubusercontent.com/AbdulRhmanAbdulGhaffar/OpenVAS-Install-All-Systems/main/openvas-install.sh | bash -s -- --wsl --yes'"

feed:
	greenbone-feed-sync || true

logs:
	bash scripts/collect-logs.sh

uninstall:
	./openvas-install.sh --uninstall --yes

reset:
	./openvas-install.sh --reset --yes

lint:
	shellcheck -x openvas-install.sh || true
	yamllint -d "extends: default" . || true
