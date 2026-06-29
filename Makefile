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

# Build settings, overridable from the environment / CI. Keep these free of
# inline comments: trailing characters would leak into image refs and flags.
REGISTRY_USERNAME ?= 127.0.0.1:5005/stagex
PLATFORM          ?= linux/amd64,linux/arm64
PROGRESS          ?= auto
BUILDER           ?= docker buildx

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
# gcc, make, musl, diffutils, go, rust) must be built in order. llvm-libgcc is a
# subpackage of llvm built as its own target. Rebase per release.
CORE := \
	filesystem busybox libzstd mimalloc musl llvm make zlib perl attr \
	linux-headers openssl pkgconf samurai cmake libucontext onetbb mold m4 autoconf \
	automake binutils bison bsd-compat-headers bzip2 ca-certificates curl diffutils libtool libffi \
	ncurses tcl sqlite3 python libxml2 gettext flex gawk gmp isl \
	libatomic_ops mpfr mpc texinfo gcc go libatomic-stub llvm-libgcc llvm21 rust

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
