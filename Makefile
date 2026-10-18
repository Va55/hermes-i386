# hermes-i386 - provisioning kit for hermes-agent on 32-bit x86 (i386).
#
# On a fresh i386 machine:
#
#     git clone https://github.com/Va55/hermes-i386.git
#     cd hermes-i386
#     make all
#
# Overridable variables:
#
#     PREFIX=$(HOME)/node22              where Node is installed
#     HERMES_SRC=$(HOME)/hermes-agent    hermes checkout
#     TARBALL=dist/node22.22.0-i386.tar.gz
#     VERSION=22.22.0                    for build-node
#

SHELL := /bin/bash
.DEFAULT_GOAL := help

PREFIX     ?= $(HOME)/node22
TARBALL    ?= dist/node22.22.0-i386.tar.gz
HERMES_SRC ?= $(HOME)/hermes-agent
VERSION    ?= 22.22.0
CHROOT     ?= /srv/i386-bookworm

.PHONY: help all node provision verify build-node checksum test-install pull clean git-access

help:
	@echo "hermes-i386 - provisioning kit for hermes-agent on 32-bit x86"
	@echo
	@echo "  make all           install Node + provision hermes + verify (recommended)"
	@echo "  make node          install the prebuilt Node for i386"
	@echo "  make provision     set up hermes-agent (venv, deps, patch, npm, launcher)"
	@echo "  make verify        check the resulting installation"
	@echo "  make build-node    rebuild Node from source (needs root; ~63 min on 8 cores)"
	@echo "  make checksum      verify the dist artifact against SHA256SUMS"
	@echo "  make test-install  install Node into a throwaway prefix as a self-test"
	@echo "  make pull          update this checkout from origin"
	@echo "  make git-access    set up SSH access so git clone works on a new box"
	@echo "  make clean         remove the installed Node prefix"
	@echo
	@echo "Variables:"
	@echo "  PREFIX     = $(PREFIX)"
	@echo "  HERMES_SRC = $(HERMES_SRC)"
	@echo "  TARBALL    = $(TARBALL)"
	@echo "  VERSION    = $(VERSION)"

all: node provision verify

node:
	@echo ">>> installing Node $(VERSION) for i386"
	@bash scripts/install-node-i386.sh "$(TARBALL)" "$(PREFIX)"

provision:
	@echo ">>> provisioning hermes-agent into $(HERMES_SRC)"
	@HERMES_SRC="$(HERMES_SRC)" bash scripts/provision-hermes-i386.sh

verify:
	@bash scripts/verify-i386.sh "$(HERMES_SRC)" "$(PREFIX)"

build-node:
	@echo ">>> building Node $(VERSION) from source in $(CHROOT)"
	@echo "    requires root; expect ~63 minutes on 8 cores"
	@sudo bash scripts/build-node-i386.sh "$(VERSION)" "$(CHROOT)"

checksum:
	@cd dist && sha256sum -c SHA256SUMS

test-install:
	@echo ">>> self-test: install Node into a throwaway prefix"
	@TMP=$$(mktemp -d) && \
	 trap 'rm -rf "$$TMP"' EXIT && \
	 bash scripts/install-node-i386.sh "$(TARBALL)" "$$TMP/prefix" && \
	 "$$TMP/prefix/bin/node" --version && \
	 "$$TMP/prefix/bin/node" -e 'new RegExp("\\p{RGI_Emoji}","v"); console.log("v-flag regex: SUPPORTED")' && \
	 echo ">>> test-install OK"

pull:
	@git pull --ff-only

git-access:
	@bash scripts/setup-git-access.sh

clean:
	@echo ">>> removing $(PREFIX)"
	@rm -rf "$(PREFIX)"
	@echo ">>> done (apt node/npm and the hermes checkout are untouched)"
