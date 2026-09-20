#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/projects.json"
PROJECT="${1:?usage: scripts/local-build-project.sh <project> [--additional]}"
ADDITIONAL=false
if [[ "${2:-}" == "--additional" ]]; then
  ADDITIONAL=true
elif [[ -n "${2:-}" ]]; then
  echo "usage: scripts/local-build-project.sh <project> [--additional]"
  exit 2
fi
LOCAL_WORK_ROOT="${LOCAL_WORK_ROOT:-$ROOT/.local-work}"
LOCAL_OUTPUT_ROOT="${LOCAL_OUTPUT_ROOT:-$ROOT/local-output}"
DEPENDENCY_OUTPUT_ROOT="${DEPENDENCY_OUTPUT_ROOT:-$LOCAL_OUTPUT_ROOT}"
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

export PROJECT_NAME="$PROJECT"
export PROJECT_ADDITIONAL="$ADDITIONAL"
export PROJECT_VARIANT="$($ADDITIONAL && printf 'additional' || printf 'base')"
export PROJECT_REPO="$(value '.projects[] | select(.name == $name) | .repo')"
export PROJECT_BRANCH="$(value '.projects[] | select(.name == $name) | .branch')"
export DEB_BUILD_OPTIONS="$(value '(.projects[] | select(.name == $name) | .deb_build_options) // .defaults.deb_build_options // "nocheck"')"
export DEBFULLNAME="$(value '(.projects[] | select(.name == $name) | .deb_fullname) // .defaults.deb_fullname // "Droidian Patch Builder"')"
export DEBEMAIL="$(value '(.projects[] | select(.name == $name) | .deb_email) // .defaults.deb_email // "builder@localhost"')"
export RELENG_FULL_BUILD=yes
export IS_CONTAINER=true

PROJECT_WORK_DIR="$LOCAL_WORK_ROOT/$PROJECT/$PROJECT_VARIANT"
export PROJECT_SOURCE_DIR="$PROJECT_WORK_DIR/source"
export PROJECT_BUILD_DIR="$PROJECT_WORK_DIR"
export PROJECT_OUTPUT_DIR="$LOCAL_OUTPUT_ROOT/$PROJECT/$PROJECT_VARIANT"

rm -rf "$PROJECT_WORK_DIR" "$PROJECT_OUTPUT_DIR"
mkdir -p "$PROJECT_SOURCE_DIR" "$PROJECT_OUTPUT_DIR"

echo "==> $PROJECT"
$ADDITIONAL && echo "    variant: additional"
echo "    repository: $PROJECT_REPO"
echo "    branch: $PROJECT_BRANCH"

git clone --branch "$PROJECT_BRANCH" --single-branch "$PROJECT_REPO" "$PROJECT_SOURCE_DIR"
cd "$PROJECT_SOURCE_DIR"
git submodule update --init --recursive

patches_applied=false
apply_patch_dir() {
  local patch_dir="$1" patch
  [[ -d "$patch_dir" ]] || return 0
  shopt -s nullglob
  local patches=("$patch_dir"/[0-9][0-9][0-9][0-9]-*.patch)
  ((${#patches[@]})) || return 0
  mapfile -t patches < <(printf '%s\n' "${patches[@]}" | sort -V)
  for patch in "${patches[@]}"; do
    echo "==> Applying $(basename "$patch")"
    git apply --check "$patch"
    git apply --index "$patch"
    patches_applied=true
  done
}

apply_patch_dir "$ROOT/patches/$PROJECT"
$ADDITIONAL && apply_patch_dir "$ROOT/patches-additional/$PROJECT"
if $patches_applied; then
  git -c user.name="$DEBFULLNAME" -c user.email="$DEBEMAIL" commit -m "build: apply local $PROJECT patches"
fi

if $ADDITIONAL; then
  cat > /etc/apt/sources.list.d/droidian-marble-build-system.list <<'EOF_APT'
deb [arch=arm64 trusted=yes] https://droidian-marble.github.io/build-system/ additional main
deb [arch=arm64 trusted=yes] https://droidian-marble.github.io/build-system/ main main
EOF_APT
else
  cat > /etc/apt/sources.list.d/droidian-marble-build-system.list <<'EOF_APT'
deb [arch=arm64 trusted=yes] https://droidian-marble.github.io/build-system/ main main
EOF_APT
fi

cat > /etc/apt/preferences.d/droidian-marble-build-system.pref <<'EOF_PREF'
Package: *:any
Pin: origin "droidian-marble.github.io"
Pin-Priority: 1003
EOF_PREF
if $ADDITIONAL; then
  cat >> /etc/apt/preferences.d/droidian-marble-build-system.pref <<'EOF_PREF'

Package: *:any
Pin: release n=additional
Pin-Priority: 1004
EOF_PREF
fi

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
while IFS=$'\t' read -r dep_project dep_additional dep_packages || [[ -n "$dep_project" ]]; do
  [[ -n "$dep_project" ]] || continue
  dep_variant="base"
  dep_artifact="project-$dep_project"
  if [[ "$dep_additional" == true ]]; then
    dep_variant="additional"
    dep_artifact+="-additional"
  fi

  dep_dir=""
  for candidate in "$DEPENDENCY_OUTPUT_ROOT/$dep_project/$dep_variant" "$DEPENDENCY_OUTPUT_ROOT/$dep_artifact"; do
    if [[ -d "$candidate" ]]; then
      dep_dir="$candidate"
      break
    fi
  done

  [[ -n "$dep_dir" ]] || {
    echo "Missing dependency artifact: $PROJECT -> $dep_project [$dep_variant]"
    exit 1
  }

  mapfile -t dep_debs < <(find "$dep_dir" -type f -name '*.deb' -print | sort)
  if ((${#dep_debs[@]} == 0)); then
    echo "Dependency artifact contains no .deb packages: $PROJECT -> $dep_project [$dep_variant]"
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
        echo "Missing dependency package: $dep_project [$dep_variant] -> $wanted"
        exit 1
      }
      dependency_debs+=("$found")
    done
  else
    dependency_debs+=("${dep_debs[@]}")
  fi
done < <(
  jq -r --arg name "$PROJECT" --argjson additional "$ADDITIONAL" '
    def dependencies_for($project; $additional):
      if $additional then
        ($project["dependencies-additional"] // []) as $overrides
        | ($overrides | map(.project)) as $override_projects
        | ([($project.dependencies // [])[] | select(.project as $dep | ($override_projects | index($dep)) == null)] + $overrides)
      else
        ($project.dependencies // [])
      end;
    (.projects[] | select(.name == $name)) as $project
    | dependencies_for($project; $additional)[]?
    | [.project, ((.additional // false) | tostring), ((.packages // []) | join(","))]
    | @tsv
  ' "$CONFIG"
)

if ((${#dependency_debs[@]})); then
  echo "==> Installing dependency artifacts"
  printf '  %s\n' "${dependency_debs[@]##*/}"
  apt-get install -y --no-install-recommends "${dependency_debs[@]}"
fi

run_script_from() {
  local root="$1" phase="$2"
  local script="$root/$phase/$PROJECT"
  [[ -f "$script" ]] || return 0
  echo "==> Running $phase script: ${script#$ROOT/}"
  (
    cd "$PROJECT_SOURCE_DIR"
    /bin/bash "$script"
  )
}

run_project_scripts() {
  local phase="$1"
  run_script_from "$ROOT/project-scripts" "$phase"
  if $ADDITIONAL; then
    run_script_from "$ROOT/project-scripts-additional" "$phase"
  fi
}

run_project_scripts before

build_command="$(value '(.projects[] | select(.name == $name) | .build_command) // .defaults.build_command // "releng-build-package"')"
echo "==> Building $PROJECT [$PROJECT_VARIANT]"
(
  cd "$PROJECT_SOURCE_DIR"
  /bin/bash -e -o pipefail -c "$build_command"
)

run_project_scripts after

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
  echo "No package artifacts were produced for $PROJECT [$PROJECT_VARIANT]"
  exit 1
fi

debs=("$PROJECT_BUILD_DIR"/*.deb)
if ((${#debs[@]} == 0)); then
  echo "No .deb packages were produced for $PROJECT [$PROJECT_VARIANT]"
  exit 1
fi

cp -a "${artifacts[@]}" "$PROJECT_OUTPUT_DIR/"
find "$PROJECT_OUTPUT_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
