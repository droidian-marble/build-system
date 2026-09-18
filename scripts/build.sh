#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/projects.json"
cd "$ROOT"
./scripts/validate.sh

if (($# == 0)); then
  mapfile -t requested < <(jq -r '.projects[] | select(.enabled) | .name' "$CONFIG")
else
  requested=("$@")
fi

declare -A state
declare -a order

deps_of() {
  jq -r --arg name "$1" \
    '.projects[] | select(.name == $name) | .dependencies[]?.project' \
    "$CONFIG"
}

visit() {
  local project="$1" dep current="${state[$1]:-0}"
  [[ "$current" == 2 ]] && return
  [[ "$current" == 1 ]] && {
    echo "Dependency cycle reached at: $project"
    exit 1
  }
  jq -e --arg name "$project" '.projects[] | select(.name == $name)' "$CONFIG" >/dev/null || {
    echo "Unknown project: $project"
    exit 1
  }
  state["$project"]=1
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && visit "$dep"
  done < <(deps_of "$project")
  state["$project"]=2
  order+=("$project")
}

for project in "${requested[@]}"; do
  visit "$project"
done

actual_arch="$(dpkg --print-architecture)"
declare -A selected_arches
for project in "${order[@]}"; do
  expected_arch="$(
    jq -r --arg name "$project" '
      (.projects[] | select(.name == $name) | .architecture)
      // .defaults.architecture
      // "arm64"
    ' "$CONFIG"
  )"
  selected_arches["$expected_arch"]=1
done

if ((${#selected_arches[@]} > 1)); then
  echo "Selected projects require multiple build architectures:"
  for arch in "${!selected_arches[@]}"; do
    printf '  %s\n' "$arch"
  done | sort
  echo "Build architecture groups separately inside their configured environments."
  exit 1
fi

for arch in "${!selected_arches[@]}"; do
  if [[ "$arch" != "$actual_arch" ]]; then
    echo "Cannot build selected projects in this container: expected $arch, got $actual_arch"
    exit 1
  fi
done

for project in "${order[@]}"; do
  DEPENDENCY_OUTPUT_ROOT="$ROOT/dist" ./scripts/build-project.sh "$project"
done
