#!/usr/bin/env python3
import os
from common import CommonUtils
from common import PackageInfo
from typing import Any
from typing import List
from typing import MutableMapping
from dataclasses import replace
from urllib.parse import urlsplit


class TargetGenerator(object):
  TARGET_TEMPLATE = """
.PHONY: {name} {stage}-{name}
{name}: out/{stage}-{name}/index.json
{stage}-{name}: out/{stage}-{name}/index.json
out/{stage}-{name}/index.json: {deps}
\trm -rf out/{stage}-{name} && \\
\tmkdir -p out/{stage}-{name} && \\
\tmkdir -p fetch/{stage}/{origin} && \\
\tpython3 src/fetch.py {origin} && \\
\t mkdir -p packages/{stage}/{origin}/fetch && \\
\t(cp -lR fetch/{stage}/{origin}/* packages/{stage}/{origin}/fetch || true) && \\
\t$(BUILDER) \\
\t  build \\
\t  --ulimit nofile=2048:16384 \\
\t  --tag stagex/{stage}-{name}:{version} \\
\t  --provenance=false \\
\t  --build-arg SOURCE_DATE_EPOCH=1 \\
\t  --build-arg BUILDKIT_MULTI_PLATFORM=1 \\
\t  --output \\
\t    name={name},type=oci,rewrite-timestamp=true,force-compression=true,annotation.org.opencontainers.image.version={version},tar=true,dest=- \\
\t  {context_args} \\
\t  {build_args} \\
\t  $(EXTRA_ARGS) \\
\t  $(NOCACHE_FLAG) \\
\t  $(CHECK_FLAG) \\
\t  --platform={platform_arg} \\
\t  --progress=$(PROGRESS) \\
\t  -f packages/{stage}/{origin}/Containerfile \\
\t  packages/{stage}/{origin} \\
\t| tar -C out/{stage}-{name} -mx

# use: make registry-{stage}-{name} BUILDER="docker buildx" REGISTRY_USERNAME=127.0.0.1:5005/stagex
# doesn't work well with docker build
registry-{stage}-{name}:
\tmkdir -p fetch/{stage}/{origin} && \\
\tpython3 src/fetch.py {origin} && \\
\t mkdir -p packages/{stage}/{origin}/fetch && \\
\t(cp -lR fetch/{stage}/{origin}/* packages/{stage}/{origin}/fetch || true) && \\
\t$(BUILDER) \\
\t  build \\
\t  --ulimit nofile=2048:16384 \\
\t  --tag $(REGISTRY_USERNAME)/{stage}-{name}:{version} \\
\t  --tag $(REGISTRY_USERNAME)/{stage}-{name}:latest \\
\t  --provenance=false \\
\t  --build-arg SOURCE_DATE_EPOCH=1 \\
\t  --build-arg BUILDKIT_MULTI_PLATFORM=1 \\
\t  --output \\
\t    name={name},type=image,rewrite-timestamp=true,annotation.org.opencontainers.image.version={version},push=true \\
\t  {context_args_registry} \\
\t  {build_args} \\
\t  $(EXTRA_ARGS) \\
\t  $(NOCACHE_FLAG) \\
\t  $(CHECK_FLAG) \\
\t  --platform={platform_arg} \\
\t  --progress=$(PROGRESS) \\
\t  -f packages/{stage}/{origin}/Containerfile \\
\t  packages/{stage}/{origin}
"""

  def __init__(self):
    self.packages: MutableMapping[str, MutableMapping[str, PackageInfo]] = dict[str, MutableMapping[str, PackageInfo]]()
    self.init_packages("packages")

    for stage, stage_packages in self.packages.items():
      print(f"\n\n.PHONY: {stage}\n{stage}:", end="")
      for name, _ in stage_packages.items():
        print(f" \\\n\t {name}", end="")

    print("\n\n.PHONY: all\nall:", end="")

    for stage, stage_packages in self.packages.items():
      for name, _ in stage_packages.items():
        print(f" \\\n\t {name}", end="")

    for stage, stage_packages in self.packages.items():
      for name, package in stage_packages.items():
        platform = "$(PLATFORM)"
        # Force platform(s) for bootstrap packages which are only available for certain architectures
        # and later cross-compile subsequent stages for the user's desired platform
        if len(package.platforms) > 0:
          platform = ",".join(package.platforms)

        print(
          TargetGenerator.TARGET_TEMPLATE.format(
            **{
              "stage": stage,
              "name": name,
              "origin": package.origin or package.name,
              "version": package.version or "latest",
              "deps": "".join(
                f" \\\n\tout/{dep}/index.json" for dep in package.deps
              ),
              "build_args": TargetGenerator.get_build_args(package),
              "context_args": TargetGenerator.get_context_args(package, stage, package.origin or package.name, False),
              "context_args_registry": TargetGenerator.get_context_args(package, stage, package.origin or package.name, True),
              "platform_arg": platform
            }
          )
        )


  def init_packages(self, root_path: str = "packages"):
    for base_dir, sub_dirs, file_list in os.walk(root_path):
      for file_name in file_list:
        if file_name == "Containerfile":
          container_file_path = os.path.join(base_dir, file_name)
          _, stage, name, _ = container_file_path.split(os.path.sep)
          package_data: MutableMapping[str, Any] | None = None
          if stage not in self.packages:
            self.packages[stage] = dict[str, PackageInfo]()

          try:
            package_data = CommonUtils.toml_read(f"{root_path}/{stage}/{name}/package.toml")
          except FileNotFoundError:
            continue

          deps: List[str] = list()
          with open(container_file_path, "r") as file:
            for line in file:
              if line.startswith("COPY"):
                first_arg = line.split(" ")[1]
                if first_arg.startswith("--from"):
                  _, dep = first_arg.split("=")
                  if dep.startswith("stagex/"):
                    deps.append(dep.split("/")[1])
              if line.startswith("FROM stagex/"):
                deps.append(line.split(" ")[1].split("/")[1].strip())
              if line.startswith("FROM --platform=linux/386 stagex/"):
                deps.append(line.split(" ")[2].split("/")[1].strip())

          package_info = CommonUtils.parse_package_toml_no_deps(package_data)
          package_info.deps = deps
          if len(package_info.subpackages):
            for subpackage in package_info.subpackages:
              self.packages[stage][subpackage] = replace(package_info)
              self.packages[stage][subpackage].origin = package_info.name
              self.packages[stage][subpackage].name = subpackage
              self.packages[stage][subpackage].subpackages = []
          else:
            self.packages[stage][name] = package_info

  @staticmethod
  def get_context_args(package: PackageInfo, stage: str, name: str, use_registry: bool) -> str:
    args: List[str] = list()
    args.append(f"--build-context fetch=fetch/{stage}/{name}")
    for dep in package.deps:
      if use_registry:
        args.append(f"--build-context stagex/{dep}=docker-image://$(REGISTRY_USERNAME)/{dep}")
      else:
        args.append(f"--build-context stagex/{dep}=oci-layout://./out/{dep}")
    return " \\\n\t  ".join(args)

  @staticmethod
  def get_build_args(package: PackageInfo) -> str:
    sources = package.sources
    args: List[str] = list()
    if package.origin:
        args.append(f"--target package-{package.name}")

    if package.version:
        args.append(f"--build-arg VERSION={package.version}")
        args.append(f"--build-arg VERSION_UNDER={package.version_under}")
        args.append(f"--build-arg VERSION_DASH={package.version_dash}")

    for source_name, source_info in sources.items():
        source_format = source_info.format
        mirrors = source_info.mirrors
        urlfile = urlsplit(mirrors[0]).path.split("/")[-1]
        # We assume that version == "" means no version was provided in toml
        if source_info.version != "":
            args.append(f"--build-arg {source_name.upper()}_VERSION={source_info.version}")
            file = source_info.file if source_info.file != "" else urlfile
            file = file.format(
                    version=source_info.version,
                    version_dash=package.version_dash,
                    version_under=package.version_under,
                    format=source_format,
                )
            args.append(f"--build-arg {source_name.upper()}_SOURCE={file}")
    return " \\\n\t  ".join(args)


if __name__ == "__main__":
  tg = TargetGenerator()


