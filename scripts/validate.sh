#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v jq >/dev/null

jq -e '
  . as $root
  | ($root.defaults | type == "object") and
    (($root.defaults.architecture // "arm64") | IN("arm64", "amd64")) and
    ($root.defaults.images | type == "object") and
    ($root.defaults.runners | type == "object") and
    ($root.defaults.images.arm64 | type == "string" and length > 0) and
    ($root.defaults.images.amd64 | type == "string" and length > 0) and
    ($root.defaults.runners.arm64 | type == "string" and length > 0) and
    ($root.defaults.runners.amd64 | type == "string" and length > 0) and
    (($root.defaults.build_command // "releng-build-package") | type == "string" and length > 0) and
    ($root.projects | type == "array") and
    ([$root.projects[].name] | length == (unique | length)) and
    all($root.projects[];
      (.name | type == "string" and test("^[A-Za-z0-9._-]+$")) and
      (.enabled | type == "boolean") and
      (.repo | type == "string" and length > 0) and
      (.branch | type == "string" and length > 0) and
      ((.architecture // $root.defaults.architecture // "arm64") | IN("arm64", "amd64")) and
      ((.image // "") | type == "string") and
      ((.runner // "") | type == "string") and
      ((.build_command // $root.defaults.build_command // "releng-build-package") | type == "string" and length > 0) and
      ((.apt_packages // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
      ((.dependencies // []) | type == "array") and
      all((.dependencies // [])[];
        (.project | type == "string" and test("^[A-Za-z0-9._-]+$")) and
        ((.packages // []) | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9.+-]+$")))
      ) and
      ([((.dependencies // [])[] | .project)] | length == (unique | length))
    )
' projects.json >/dev/null

mapfile -t names < <(jq -r '.projects[].name' projects.json)
declare -A exists visiting visited
for name in "${names[@]}"; do exists["$name"]=1; done

for name in "${names[@]}"; do
  arch="$(
    jq -r --arg name "$name" '
      (.projects[] | select(.name == $name) | .architecture)
      // .defaults.architecture
      // "arm64"
    ' projects.json
  )"
  image="$(
    jq -r --arg name "$name" --arg arch "$arch" '
      (.projects[] | select(.name == $name) | .image)
      // .defaults.images[$arch]
      // empty
    ' projects.json
  )"
  runner="$(
    jq -r --arg name "$name" --arg arch "$arch" '
      (.projects[] | select(.name == $name) | .runner)
      // .defaults.runners[$arch]
      // empty
    ' projects.json
  )"
  [[ -n "$image" ]] || { echo "Missing container image for $name [$arch]"; exit 1; }
  [[ -n "$runner" ]] || { echo "Missing runner for $name [$arch]"; exit 1; }

  while IFS= read -r dep; do
    [[ ${exists[$dep]:-0} == 1 ]] || {
      echo "Unknown dependency: $name -> $dep"
      exit 1
    }
  done < <(
    jq -r --arg name "$name" \
      '.projects[] | select(.name == $name) | .dependencies[]?.project' \
      projects.json
  )
done

check_cycle() {
  local project="$1" dep
  [[ ${visited[$project]:-0} == 1 ]] && return
  [[ ${visiting[$project]:-0} == 1 ]] && {
    echo "Dependency cycle detected at: $project"
    exit 1
  }
  visiting["$project"]=1
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && check_cycle "$dep"
  done < <(
    jq -r --arg name "$project" \
      '.projects[] | select(.name == $name) | .dependencies[]?.project' \
      projects.json
  )
  visiting["$project"]=0
  visited["$project"]=1
}
for name in "${names[@]}"; do check_cycle "$name"; done

for phase in before after; do
  dir="project-scripts/$phase"
  [[ -d "$dir" ]] || { echo "Missing project script directory: $dir"; exit 1; }
  while IFS= read -r script; do
    base="$(basename "$script")"
    [[ "$base" == "README.md" ]] && continue
    [[ ${exists[$base]:-0} == 1 ]] || {
      echo "Unknown project script: $script"
      exit 1
    }
  done < <(find "$dir" -maxdepth 1 -type f -print | sort)
done

if [[ -d patches ]]; then
  while IFS= read -r patch_dir; do
    project="$(basename "$patch_dir")"
    [[ ${exists[$project]:-0} == 1 ]] || {
      echo "Unknown project patch directory: $patch_dir"
      exit 1
    }

    declare -A patch_sequences=()
    while IFS= read -r patch; do
      base="$(basename "$patch")"
      [[ "$base" =~ ^([0-9]{4})-.+\.patch$ ]] || {
        echo "Invalid active patch name: $patch (expected 0001-description.patch)"
        exit 1
      }
      sequence="${BASH_REMATCH[1]}"
      [[ -z "${patch_sequences[$sequence]+x}" ]] || {
        echo "Duplicate patch sequence for $project: $sequence"
        exit 1
      }
      patch_sequences["$sequence"]="$base"
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print | sort -V)
  done < <(find patches -mindepth 1 -maxdepth 1 -type d -print | sort)

  while IFS= read -r patch; do
    relative="${patch#patches/}"
    project="${relative%%/*}"
    remainder="${relative#*/}"
    [[ "$remainder" != */* ]] || {
      echo "Nested active patch is not supported: $patch"
      exit 1
    }
    [[ ${exists[$project]:-0} == 1 ]] || {
      echo "Unknown project patch: $patch"
      exit 1
    }
  done < <(find patches -type f -name '*.patch' -print | sort -V)
fi

./scripts/ci-plan.sh >/dev/null
echo "Configuration is valid."
