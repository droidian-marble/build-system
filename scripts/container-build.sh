#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive RELENG_FULL_BUILD=yes
rm -rf /buildd/sources
mkdir -p /buildd/sources /output
echo "==> Cloning $PROJECT_NAME: $PROJECT_REPO [$PROJECT_BRANCH]"
git clone --branch "$PROJECT_BRANCH" --single-branch "$PROJECT_REPO" /buildd/sources
cd /buildd/sources
git submodule update --init --recursive
shopt -s nullglob
patches=(/patches/[0-9][0-9][0-9][0-9]-*.patch)
if ((${#patches[@]})); then
  mapfile -t patches < <(printf '%s\n' "${patches[@]}" | sort -V)
  for patch in "${patches[@]}"; do echo "==> Applying $(basename "$patch")"; git apply --check "$patch"; git apply --index "$patch"; done
  git -c user.name="$DEBFULLNAME" -c user.email="$DEBEMAIL" commit -m "build: apply local $PROJECT_NAME patches"
fi
apt-get update
if [[ -n "${PROJECT_APT_PACKAGES:-}" ]]; then read -r -a apt_packages <<< "$PROJECT_APT_PACKAGES"; apt-get install -y --no-install-recommends "${apt_packages[@]}"; fi
if [[ -n "${PROJECT_DEPENDENCIES_B64:-}" ]]; then
  dependency_debs=()
  while IFS=$'\t' read -r dep_project dep_packages || [[ -n "$dep_project" ]]; do
    [[ -n "$dep_project" ]] || continue
    dep_dir="/dependencies/$dep_project"
    [[ -d "$dep_dir" ]] || { echo "Missing dependency output directory: $dep_project"; exit 1; }
    if [[ -n "${dep_packages:-}" ]]; then
      IFS=',' read -r -a wanted_packages <<< "$dep_packages"
      for wanted in "${wanted_packages[@]}"; do
        found=""
        for deb in "$dep_dir"/*.deb; do
          [[ -e "$deb" ]] || continue
          [[ "$(dpkg-deb -f "$deb" Package)" == "$wanted" ]] || continue
          arch="$(dpkg-deb -f "$deb" Architecture)"
          case "$arch" in arm64|all) found="$deb"; break ;; esac
        done
        [[ -n "$found" ]] || { echo "Missing dependency package: $dep_project -> $wanted"; exit 1; }
        dependency_debs+=("$found")
      done
    else
      for deb in "$dep_dir"/*.deb; do
        [[ -e "$deb" ]] || continue
        arch="$(dpkg-deb -f "$deb" Architecture)"
        case "$arch" in arm64|all) dependency_debs+=("$deb") ;; esac
      done
    fi
  done < <(printf '%s' "$PROJECT_DEPENDENCIES_B64" | base64 -d)
  if ((${#dependency_debs[@]})); then
    echo "==> Installing dependency outputs"
    printf '  %s\n' "${dependency_debs[@]##*/}"
    apt-get install -y --no-install-recommends "${dependency_debs[@]}"
  fi
fi
if [[ -n "${PROJECT_BEFORE_BUILD_B64:-}" ]]; then printf '%s' "$PROJECT_BEFORE_BUILD_B64" | base64 -d > /tmp/droidian-before-build.sh; chmod +x /tmp/droidian-before-build.sh; /tmp/droidian-before-build.sh; fi
echo "==> Source commit"
git rev-parse HEAD
git status --short
echo "==> Building $PROJECT_NAME natively on $(uname -m)"
releng-build-package
echo "==> Collecting output"
artifacts=(/buildd/*.deb /buildd/*.ddeb /buildd/*.changes /buildd/*.buildinfo /buildd/*.dsc /buildd/*.tar.*)
if ((${#artifacts[@]} == 0)); then echo "No package artifacts were produced for $PROJECT_NAME"; exit 1; fi
cp -a "${artifacts[@]}" /output/
printf '%s\n' "${artifacts[@]##*/}" | sort
