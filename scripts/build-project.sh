#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/projects.json"
PROJECT="${1:?usage: scripts/build-project.sh <project>}"
DEPENDENCY_OUTPUT_ROOT="${DEPENDENCY_OUTPUT_ROOT:-$ROOT/dist}"
cd "$ROOT"

for cmd in jq git dpkg dpkg-deb apt-get; do
  command -v "$cmd" >/dev/null || {
    echo "Missing command: $cmd"
    exit 1
  }
done

project_exists() {
  jq -e --arg name "$PROJECT" '.projects[] | select(.name == $name)' "$CONFIG" >/dev/null
}
project_exists || {
  echo "Unknown project: $PROJECT"
  exit 1
}

value() {
  jq -r --arg name "$PROJECT" "$1" "$CONFIG"
}

PROJECT_ARCHITECTURE="$(value '(.projects[] | select(.name == $name) | .architecture) // .defaults.architecture // "arm64"')"
actual_arch="$(dpkg --print-architecture)"
if [[ "$actual_arch" != "$PROJECT_ARCHITECTURE" ]]; then
  echo "Container architecture mismatch for $PROJECT: expected $PROJECT_ARCHITECTURE, got $actual_arch"
  exit 1
fi

export PROJECT_NAME="$PROJECT"
export PROJECT_REPO="$(value '.projects[] | select(.name == $name) | .repo')"
export PROJECT_BRANCH="$(value '.projects[] | select(.name == $name) | .branch')"
export DEB_BUILD_OPTIONS="$(value '(.projects[] | select(.name == $name) | .deb_build_options) // .defaults.deb_build_options // "nocheck"')"
export DEBFULLNAME="$(value '(.projects[] | select(.name == $name) | .deb_fullname) // .defaults.deb_fullname // "Droidian Patch Builder"')"
export DEBEMAIL="$(value '(.projects[] | select(.name == $name) | .deb_email) // .defaults.deb_email // "builder@localhost"')"
export RELENG_FULL_BUILD=yes

if [[ "${GITHUB_ACTIONS:-}" == "true" || -e /.dockerenv || -e /run/.containerenv ]]; then
  export IS_CONTAINER=true
fi

PROJECT_WORK_DIR="$ROOT/.work/$PROJECT"
export PROJECT_SOURCE_DIR="$PROJECT_WORK_DIR/source"
export PROJECT_BUILD_DIR="$PROJECT_WORK_DIR"
export PROJECT_OUTPUT_DIR="$ROOT/dist/$PROJECT"

rm -rf "$PROJECT_WORK_DIR" "$PROJECT_OUTPUT_DIR"
mkdir -p "$PROJECT_SOURCE_DIR" "$PROJECT_OUTPUT_DIR"

echo "==> $PROJECT"
echo "    repository: $PROJECT_REPO"
echo "    branch: $PROJECT_BRANCH"

git clone --branch "$PROJECT_BRANCH" --single-branch "$PROJECT_REPO" "$PROJECT_SOURCE_DIR"
cd "$PROJECT_SOURCE_DIR"
git submodule update --init --recursive

patch_dir="$ROOT/patches/$PROJECT"
if [[ -d "$patch_dir" ]]; then
  shopt -s nullglob
  patches=("$patch_dir"/[0-9][0-9][0-9][0-9]-*.patch)
  if ((${#patches[@]})); then
    mapfile -t patches < <(printf '%s\n' "${patches[@]}" | sort -V)
    for patch in "${patches[@]}"; do
      echo "==> Applying $(basename "$patch")"
      git apply --check "$patch"
      git apply --index "$patch"
    done
    git -c user.name="$DEBFULLNAME" -c user.email="$DEBEMAIL" \
      commit -m "build: apply local $PROJECT patches"
  fi
fi

cat > /etc/apt/sources.list.d/droidian-marble-build-system.list <<'EOF'
deb [arch=arm64 trusted=yes] https://droidian-marble.github.io/build-system/ main main
EOF

cat > /etc/apt/preferences.d/droidian-marble-build-system.pref <<'EOF'
Package: *:any
Pin: origin "droidian-marble.github.io"
Pin-Priority: 1001
EOF

apt-get update
mapfile -t apt_packages < <(
  jq -r --arg name "$PROJECT" '
    [
      .defaults.apt_packages[]?,
      (.projects[] | select(.name == $name) | .apt_packages[]?)
    ]
    | unique[]
  ' "$CONFIG"
)
if ((${#apt_packages[@]})); then
  apt-get install -y --no-install-recommends "${apt_packages[@]}"
fi

dependency_debs=()
while IFS=$'\t' read -r dep_project dep_packages || [[ -n "$dep_project" ]]; do
  [[ -n "$dep_project" ]] || continue

  dep_dir=""
  for candidate in \
    "$DEPENDENCY_OUTPUT_ROOT/project-$dep_project" \
    "$DEPENDENCY_OUTPUT_ROOT/$dep_project"; do
    if [[ -d "$candidate" ]]; then
      dep_dir="$candidate"
      break
    fi
  done

  [[ -n "$dep_dir" ]] || {
    echo "Missing dependency artifact: $PROJECT -> $dep_project"
    exit 1
  }

  mapfile -t dep_debs < <(find "$dep_dir" -type f -name '*.deb' -print | sort)
  if ((${#dep_debs[@]} == 0)); then
    echo "Dependency artifact contains no .deb packages: $PROJECT -> $dep_project"
    exit 1
  fi

  if [[ -n "${dep_packages:-}" ]]; then
    IFS=',' read -r -a wanted_packages <<< "$dep_packages"
    for wanted in "${wanted_packages[@]}"; do
      found=""
      for deb in "${dep_debs[@]}"; do
        [[ "$(dpkg-deb -f "$deb" Package)" == "$wanted" ]] || continue
        found="$deb"
        break
      done
      [[ -n "$found" ]] || {
        echo "Missing dependency package: $dep_project -> $wanted"
        exit 1
      }
      dependency_debs+=("$found")
    done
  else
    dependency_debs+=("${dep_debs[@]}")
  fi
done < <(
  jq -r --arg name "$PROJECT" '
    .projects[]
    | select(.name == $name)
    | .dependencies[]?
    | [.project, ((.packages // []) | join(","))]
    | @tsv
  ' "$CONFIG"
)

if ((${#dependency_debs[@]})); then
  echo "==> Installing dependency artifacts"
  printf '  %s\n' "${dependency_debs[@]##*/}"
  apt-get install -y --no-install-recommends "${dependency_debs[@]}"
fi

run_project_script() {
  local phase="$1"
  local script="$ROOT/project-scripts/$phase/$PROJECT"
  [[ -f "$script" ]] || return 0
  echo "==> Running $phase script"
  (
    cd "$PROJECT_SOURCE_DIR"
    /bin/bash "$script"
  )
}

run_project_script before

build_command="$(value '(.projects[] | select(.name == $name) | .build_command) // .defaults.build_command // "releng-build-package"')"
echo "==> Building $PROJECT"
(
  cd "$PROJECT_SOURCE_DIR"
  /bin/bash -e -o pipefail -c "$build_command"
)

run_project_script after

echo "==> Collecting artifacts"
shopt -s nullglob
artifacts=(
  "$PROJECT_BUILD_DIR"/*.deb
  "$PROJECT_BUILD_DIR"/*.ddeb
  "$PROJECT_BUILD_DIR"/*.changes
  "$PROJECT_BUILD_DIR"/*.buildinfo
  "$PROJECT_BUILD_DIR"/*.dsc
  "$PROJECT_BUILD_DIR"/*.tar.*
)
if ((${#artifacts[@]} == 0)); then
  echo "No package artifacts were produced for $PROJECT"
  exit 1
fi

cp -a "${artifacts[@]}" "$PROJECT_OUTPUT_DIR/"
find "$PROJECT_OUTPUT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
