# A CI pipeline for \[Stageˣ\]

> This is not the upstream project, nor a fork, it is a CI repository used to build AMD64+ARM64 multiplatform images in GitHub Actions

[git://codeberg.org:stagex/stagex](https://codeberg.org/stagex/stagex) | [matrix://#stagex:matrix.org](https://matrix.to/#/#stagex:matrix.org) | [ircs://irc.oftc.net:6697#stagex](https://webchat.oftc.net/?channels=stagex&uio=MT11bmRlZmluZWQmMTE9MTk14d)

## How it works

This repository wraps the upstream [StageX](https://codeberg.org/stagex/stagex)
build: it checks out the upstream tree, applies a small set of siderolabs
patches and builds the bootstrap stages and core packages for `linux/amd64` and
`linux/arm64`, pushing the intermediate results to a container registry.

All of the build logic lives in the [`Makefile`](Makefile). The
[GitHub Actions workflow](.github/workflows/ci.yaml) only calls into it, so the
same steps can be run locally. The workflow is generated from
[`.kres.yaml`](.kres.yaml) by [kres](https://github.com/siderolabs/kres); run
`make rekres` after editing `.kres.yaml`.

The StageX version is pinned once via `STAGEX_REF` in the `Makefile`.

## Building

```sh
make all        # clone + patch + fetch + build everything
```

Or step by step:

```sh
make clone      # clone upstream StageX at STAGEX_REF into _out/stagex
make patch      # apply the siderolabs patches
make fetch      # pre-fetch source tarballs
make bootstrap  # build the bootstrap stages (stage0..stage3, amd64)
make core       # build the core packages in dependency order
```

Individual targets work too (`make stage0`, `make binutils`, …), provided
their dependencies have already been built and pushed.

Run `make help` for the full list of targets.

Useful variables (override on the command line or via the environment):

| Variable            | Default                   | Purpose                                         |
| ------------------- | ------------------------- | ----------------------------------------------- |
| `STAGEX_REF`        | pinned in the `Makefile`  | upstream ref (tag/branch/sha) to build          |
| `REGISTRY_USERNAME` | `127.0.0.1:5000/stagex`   | registry url/namespace to push to               |
| `PLATFORM`          | `linux/amd64,linux/arm64` | platforms to build (bootstrap stages are amd64) |
| `BUILDER`           | `docker buildx`           | build backend                                   |

Builds push to a registry (`push=true`), so a local build needs a writable
registry and a `docker-container` buildx builder, e.g.:

```sh
docker run -d -p 5000:5000 --name registry registry:2
docker buildx create --name stagex --driver docker-container --driver-opt network=host --bootstrap --use
make all REGISTRY_USERNAME=127.0.0.1:5000/stagex
```

### Patches

The patches applied to the upstream tree are kept to a minimum and rebased per
release:

- `0001-fix-make-stage3-cross-compile-for-linux-arm64-again.patch` — upstream
  bug fix: `stage3` cross-compiles busybox/libunwind for `linux/arm64` without
  executing the cross-built binaries on the build host. Should be upstreamed.
- `0002-fix-core-llvm-rm-nsan-on-arm64.patch` — upstream bug fix: `rm -f` the
  x86-only NSan runtime so the `core-llvm` install step does not fail on
  `linux/arm64` (where it is never built). Should be upstreamed.
- `0003-fix-core-rust-add-aarch64-musl-mrustc-target.patch` — upstream bug fix:
  teach the `mrustc` Rust bootstrapper the `aarch64-unknown-linux-musl` target
  so `core-rust` bootstraps `rustc` on `linux/arm64`. Should be upstreamed (to
  StageX, and ideally the target to mrustc).
- `tag.patch` — tag `registry-*` images with `:$(TAG)` (the StageX ref) in
  addition to `:latest`.
- `ttl.sh.patch` — also push images to `ttl.sh` for ephemeral sharing.
