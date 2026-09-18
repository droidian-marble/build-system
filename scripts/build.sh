#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/validate.sh

if (($# == 0)); then
  mapfile -t requested < <(jq -r '.projects[] | select(.enabled) | .name' projects.json)
else
  requested=("$@")
fi

declare -A state
declare -a order

deps_of() {
  jq -r --arg name "$1" \
    '.projects[] | select(.name == $name) | .dependencies[]?.project' \
    projects.json
}

visit() {
  local project="$1" dep current="${state[$1]:-0}"
  [[ "$current" == 2 ]] && return
  [[ "$current" == 1 ]] && {
    echo "Dependency cycle reached at: $project"
    exit 1
  }
  jq -e --arg name "$project" '.projects[] | select(.name == $name)' projects.json >/dev/null || {
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
for project in "${order[@]}"; do
  expected_arch="$(
    jq -r --arg name "$project" '
      (.projects[] | select(.name == $name) | .architecture)
      // .defaults.architecture
      // "arm64"
    ' projects.json
  )"
  if [[ "$expected_arch" != "$actual_arch" ]]; then
    echo "Cannot build $project in this container: expected $expected_arch, got $actual_arch"
    echo "Run that project inside its configured Droidian image instead."
    exit 1
  fi
  DEPENDENCY_OUTPUT_ROOT="$ROOT/dist" ./scripts/build-project.sh "$project"
done
