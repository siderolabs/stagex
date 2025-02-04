STAGES := pallet bootstrap core user## Namespaces to build
PROGRESS := auto## Buildkit progress output style
PLATFORM := linux/amd64## Platform we are building for
BUILDER := $(shell command -v docker) ## Build backend to use
REGISTRY_USERNAME := 127.0.0.1:5000/stagex## Example for registry-* targets
REGISTRY := stagex## Registry url/namespace to build/publish for
CHECK ?= 0## Run build with syntax checking enabled
NOCACHE ?= 0## Run build ignoring all existing cache

include src/global.mk
include src/macros.mk

all: $(STAGES) ## Build entire tree (default)

check: ## Run syntax checking and linting across tree
	@$(MAKE) CHECK=1 all

verify: ## Verify local build against committed digests
	@$(call verify)

digests: all ## Generate new digests from full tree
	@./src/digests.py

sign: digests ## Sign all digests that match locally built targets
	@$(call sign)

compat: ## Check system compatibility for reproducible builds
	@./src/compat.sh

preseed: ## Seed build cache from last published release
	@./src/preseed.sh

fetch: ## Fetch and hash verify all external source files
	@./src/fetch.py

help:
	@./src/help.sh Makefile
