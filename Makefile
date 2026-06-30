# This repository is a CI wrapper around upstream StageX: it checks out the
# upstream tree, applies a small set of siderolabs patches and builds the
# bootstrap + core packages for linux/amd64 and linux/arm64, pushing the
# intermediate results to a container registry.
#
# All build settings live here so they are defined once and shared between
# local runs and the GitHub Actions workflow (which only calls into this
# Makefile). The generated workflow lives in .github/workflows and is produced
# from .kres.yaml via `make rekres`.

# StageX upstream tree and the ref to build. STAGEX_REF is the single source of
# truth for the version: CI may pass it through (possibly empty), in which case
# we fall back to the pinned default below.
STAGEX_REPO ?= https://codeberg.org/stagex/stagex.git
STAGEX_REF  := $(or $(strip $(STAGEX_REF)),2026.06.0)
STAGEX_DIR  ?= _out/stagex

# Source-cache image: a flat image holding the pre-fetched `fetch/` tree, keyed
# by the upstream ref. Pulled to seed fetch.py so static sources skip the mirror
# round-trip. Always ghcr.io (public) so PR builds can pull it without auth — do
# not derive from REGISTRY_USERNAME, which points at the dev registry on PRs.
FETCH_CACHE_IMAGE ?= ghcr.io/siderolabs/stagex/fetch-cache:$(STAGEX_REF)

# Build settings, overridable from the environment / CI. Keep these free of
# inline comments: trailing characters would leak into image refs and flags.
REGISTRY_USERNAME ?= 127.0.0.1:5005/stagex
PLATFORM          ?= linux/amd64,linux/arm64
PROGRESS          ?= auto
BUILDER           ?= docker buildx

# stage3 and go bootstrap from an i386 base and cross-compile to the target, so
# their arm64 output must be built on an amd64 node (native i386 bootstrap) and
# not emulated on the arm64 node: go's i386 Go bootstrap crashes under qemu
# (go1.4 predates arm64) and stage3's i386 cross steps are very slow emulated.
# CI sets this to a dedicated amd64-only buildx builder; empty locally (uses the
# default BUILDER, single node).
CROSS_BUILDER_NAME ?=

# Patches applied to the upstream tree, in order. The stage3 fix is an
# upstream-bound bug fix; tag.patch / ttl.sh.patch are siderolabs-specific.
PATCHES := \
	0001-fix-make-stage3-cross-compile-for-linux-arm64-again.patch \
	0002-fix-core-llvm-rm-nsan-on-arm64.patch \
	tag.patch \
	ttl.sh.patch

# Bootstrap stages (seed the toolchain, amd64-only).
BOOTSTRAP := stage0 stage1 stage2 stage3

# Core packages in topological (dependency) order. Each registry-* build pulls
# its dependencies from the registry rather than building them, so the full
# dependency closure of the packages we consume (filesystem, binutils, busybox,
# gcc, make, musl, diffutils, go) must be built in order. Rebase per release.
# rust is deferred: arm64 rust needs an amd64-cross bootstrap rework (mrustc
# 0.12.0 can't compile Rust core for aarch64); it will return in a separate change.
CORE := \
	filesystem busybox libzstd mimalloc musl llvm make zlib perl attr \
	linux-headers openssl pkgconf samurai cmake libucontext onetbb mold m4 autoconf \
	automake binutils bison bsd-compat-headers bzip2 diffutils libtool libffi ncurses tcl \
	sqlite3 python libxml2 gettext flex gawk gmp isl libatomic_ops mpfr \
	mpc texinfo gcc go

# Source tarballs to pre-fetch before building (fail fast on mirror issues).
FETCH_PACKAGES := $(CORE) $(BOOTSTRAP)

PATCH_STAMP := $(STAGEX_DIR)/.stagex-patched

# Run an upstream registry-* target with our settings. $(1) is the upstream
# make target. Variables are passed on the command line so they override the
# upstream Makefile's `:=` assignments.
define registry-build
$(MAKE) -C $(STAGEX_DIR) $(1) \
	BUILDER="$(BUILDER)" \
	PROGRESS="$(PROGRESS)" \
	PLATFORM="$(PLATFORM)" \
	REGISTRY_USERNAME="$(REGISTRY_USERNAME)" \
	TAG="$(STAGEX_REF)"
endef

.PHONY: all
all: fetch build ## Clone, patch, fetch and build the whole tree (default)

.PHONY: build
build: bootstrap core ## Build all bootstrap stages and core packages in order

.PHONY: bootstrap
bootstrap: $(BOOTSTRAP) ## Build the bootstrap stages (stage0-stage3)

.PHONY: core
core: $(CORE) ## Build the core packages in dependency order

# Bootstrap seed stages are amd64-only; they build the cross/native toolchain
# that later (multi-arch) stages depend on.
stage0 stage1 stage2: PLATFORM := linux/amd64

# Route the i386-bootstrap cross-compiled packages to the amd64 builder (see
# CROSS_BUILDER_NAME above). Only takes effect when CROSS_BUILDER_NAME is set.
ifneq ($(strip $(CROSS_BUILDER_NAME)),)
stage3 go: BUILDER := $(BUILDER) --builder $(CROSS_BUILDER_NAME)
endif

.PHONY: $(BOOTSTRAP)
$(BOOTSTRAP): | $(PATCH_STAMP)
	$(call registry-build,registry-bootstrap-$@)

.PHONY: $(CORE)
$(CORE): | $(PATCH_STAMP)
	$(call registry-build,registry-core-$@)

$(STAGEX_DIR):
	git clone $(STAGEX_REPO) $@ --depth 1 -b $(STAGEX_REF)
	@git -C $@ log -n 1 --oneline

.PHONY: clone
clone: | $(STAGEX_DIR) ## Clone the upstream StageX tree at STAGEX_REF

$(PATCH_STAMP): $(PATCHES) | $(STAGEX_DIR)
	for p in $(PATCHES); do patch -d $(STAGEX_DIR) -p1 < $$p; done
	touch $@

.PHONY: patch
patch: $(PATCH_STAMP) ## Apply the siderolabs patches to the StageX tree

.PHONY: fetch
fetch: | $(PATCH_STAMP) ## Pre-fetch source tarballs for the build
	cd $(STAGEX_DIR) && python3 ./src/fetch.py $(FETCH_PACKAGES)

# Seed the fetch cache from the ghcr.io cache image before building. fetch.py
# verifies each cached file's sha256 and skips its download on a match, so this
# is purely additive: only new/changed sources still hit upstream mirrors, and a
# stale or missing cache only slows the build (never breaks it). Best-effort: a
# missing image just warns and lets fetch.py download everything as before.
.PHONY: fetch-seed
fetch-seed: | $(PATCH_STAMP) ## Seed the fetch cache from the ghcr.io cache image
	if crane export $(FETCH_CACHE_IMAGE) - > $(STAGEX_DIR)/.seed.tar; then \
		tar -x -C $(STAGEX_DIR) -f $(STAGEX_DIR)/.seed.tar; \
		echo "Seeded fetch cache from $(FETCH_CACHE_IMAGE)"; \
	else \
		echo "WARNING: fetch-cache $(FETCH_CACHE_IMAGE) unavailable; continuing without seed"; \
	fi
	rm -f $(STAGEX_DIR)/.seed.tar

# Package the locally fetched source tree and push it as the cache image. Run
# this after `make fetch` (so $(STAGEX_DIR)/fetch is fully populated) and after
# `crane auth login ghcr.io`. Refresh when STAGEX_REF changes.
.PHONY: fetch-cache-push
fetch-cache-push: | $(PATCH_STAMP) ## Package the fetched sources and push the cache image
	tar -C $(STAGEX_DIR) -cf $(STAGEX_DIR)/.fetch-cache.tar fetch
	crane append -f $(STAGEX_DIR)/.fetch-cache.tar -t $(FETCH_CACHE_IMAGE)
	rm -f $(STAGEX_DIR)/.fetch-cache.tar

.PHONY: clean
clean: ## Remove the checked out StageX tree
	rm -rf $(STAGEX_DIR)

# Builds are ordered: each stage depends on the previous one's images.
.NOTPARALLEL:

KRES_IMAGE ?= ghcr.io/siderolabs/kres:latest

.PHONY: rekres
rekres:
	@docker pull $(KRES_IMAGE)
	@docker run --rm --net=host --user $(shell id -u):$(shell id -g) -v $(PWD):/src -w /src -e GITHUB_TOKEN $(KRES_IMAGE)

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
