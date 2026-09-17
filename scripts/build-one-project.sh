#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${1:?usage: scripts/build-one-project.sh <project>}"
cd "$ROOT"
case "$(uname -m)" in aarch64|arm64) ;; *) echo "Native ARM64 host required; refusing cross/emulated build on $(uname -m)."; exit 1 ;; esac
for cmd in jq podman base64; do command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }; done
if ! jq -e --arg name "$PROJECT" '.projects[] | select(.name == $name)' projects.json >/dev/null; then echo "Unknown project: $PROJECT"; exit 1; fi
value() { jq -r --arg name "$PROJECT" "$1" projects.json; }
export PROJECT_NAME="$PROJECT"
export PROJECT_REPO="$(value '.projects[] | select(.name == $name) | .repo')"
export PROJECT_BRANCH="$(value '.projects[] | select(.name == $name) | .branch')"
export DROIDIAN_BUILD_IMAGE="$(value '(.projects[] | select(.name == $name) | .image) // .defaults.image')"
export PROJECT_DEB_BUILD_OPTIONS="$(value '(.projects[] | select(.name == $name) | .deb_build_options) // .defaults.deb_build_options // "nocheck"')"
export PROJECT_DEBFULLNAME="$(value '(.projects[] | select(.name == $name) | .deb_fullname) // .defaults.deb_fullname // "Droidian Patch Builder"')"
export PROJECT_DEBEMAIL="$(value '(.projects[] | select(.name == $name) | .deb_email) // .defaults.deb_email // "builder@localhost"')"
export PROJECT_APT_PACKAGES="$(value '[.defaults.apt_packages[]?, (.projects[] | select(.name == $name) | .apt_packages[]?)] | unique | join(" ")')"
before_build="$(value '(.projects[] | select(.name == $name) | .before_build) // ""')"
export PROJECT_BEFORE_BUILD_B64="$(printf '%s' "$before_build" | base64 | tr -d '\n')"
dependency_manifest="$(jq -r --arg name "$PROJECT" '.projects[] | select(.name == $name) | .dependencies[]? | [.project, ((.packages // []) | join(","))] | @tsv' projects.json)"
export PROJECT_DEPENDENCIES_B64="$(printf '%s' "$dependency_manifest" | base64 | tr -d '\n')"
export PROJECT_WORK_DIR="$ROOT/.work/$PROJECT"
export PROJECT_PATCH_DIR="$ROOT/patches/$PROJECT"
export PROJECT_OUTPUT_DIR="$ROOT/dist/$PROJECT"
export DEPENDENCY_OUTPUT_ROOT="$ROOT/dist"
mkdir -p "$PROJECT_PATCH_DIR" "$DEPENDENCY_OUTPUT_ROOT"
rm -rf "$PROJECT_WORK_DIR" "$PROJECT_OUTPUT_DIR"
mkdir -p "$PROJECT_WORK_DIR" "$PROJECT_OUTPUT_DIR"
echo "==> Pulling $DROIDIAN_BUILD_IMAGE"
podman pull "$DROIDIAN_BUILD_IMAGE"
echo "==> Building $PROJECT"
PODMAN_COMPOSE_PROVIDER=podman-compose podman compose -f compose.yaml run --rm builder
echo "==> Output: $PROJECT_OUTPUT_DIR"
find "$PROJECT_OUTPUT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
