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
      (.base | type == "boolean") and
      ((.additional // false) | type == "boolean") and
      (.repo | type == "string" and length > 0) and
      (.branch | type == "string" and length > 0) and
      ((.architecture // $root.defaults.architecture // "arm64") | IN("arm64", "amd64")) and
      ((.image // "") | type == "string") and
      ((.runner // "") | type == "string") and
      ((.build_command // $root.defaults.build_command // "releng-build-package") | type == "string" and length > 0) and
      ((.apt_packages // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
      ((.dependencies // []) | type == "array") and
      ((.["dependencies-additional"] // []) | type == "array") and
      all((((.dependencies // []) + (.["dependencies-additional"] // [])))[];
        (.project | type == "string" and test("^[A-Za-z0-9._-]+$")) and
        ((.additional // false) | type == "boolean") and
        ((.packages // []) | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9.+-]+$")))
      ) and
      ([((.dependencies // [])[] | .project)] | length == (unique | length)) and
      ([((.["dependencies-additional"] // [])[] | .project)] | length == (unique | length))
    )
' projects.json >/dev/null

mapfile -t names < <(jq -r '.projects[].name' projects.json)
declare -A exists visiting visited
for name in "${names[@]}"; do exists["$name"]=1; done

dependencies_for() {
  local project="$1" additional="$2"
  jq -r --arg name "$project" --argjson additional "$additional" '
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
    | [.project, ((.additional // false) | tostring)]
    | @tsv
  ' projects.json
}

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

  for consumer_additional in false true; do
    while IFS=$'\t' read -r dep dep_additional; do
      [[ -n "$dep" ]] || continue
      [[ ${exists[$dep]:-0} == 1 ]] || {
        echo "Unknown dependency: $name -> $dep"
        exit 1
      }
    done < <(dependencies_for "$name" "$consumer_additional")
  done
done

check_cycle() {
  local key="$1" project="${1%|*}" additional="${1##*|}" dep dep_additional dep_key label
  [[ ${visited[$key]:-0} == 1 ]] && return
  if [[ ${visiting[$key]:-0} == 1 ]]; then
    label="$project"
    [[ "$additional" == true ]] && label+="-additional"
    echo "Dependency cycle detected at: $label"
    exit 1
  fi
  visiting["$key"]=1
  while IFS=$'\t' read -r dep dep_additional; do
    [[ -n "$dep" ]] || continue
    dep_key="$dep|$dep_additional"
    check_cycle "$dep_key"
  done < <(dependencies_for "$project" "$additional")
  visiting["$key"]=0
  visited["$key"]=1
}
for name in "${names[@]}"; do
  check_cycle "$name|false"
  check_cycle "$name|true"
done

validate_script_tree() {
  local root="$1" required="$2" phase dir script base
  for phase in before after; do
    dir="$root/$phase"
    if [[ ! -d "$dir" ]]; then
      [[ "$required" == true ]] && { echo "Missing project script directory: $dir"; exit 1; }
      continue
    fi
    while IFS= read -r script; do
      base="$(basename "$script")"
      [[ "$base" == "README.md" ]] && continue
      [[ ${exists[$base]:-0} == 1 ]] || {
        echo "Unknown project script: $script"
        exit 1
      }
    done < <(find "$dir" -maxdepth 1 -type f -print | sort)
  done
}

validate_patch_tree() {
  local root="$1" patch_dir project patch base sequence relative remainder
  [[ -d "$root" ]] || return 0

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
        echo "Duplicate patch sequence for $project in $root: $sequence"
        exit 1
      }
      patch_sequences["$sequence"]="$base"
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print | sort -V)
    unset patch_sequences
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print | sort)

  while IFS= read -r patch; do
    relative="${patch#$root/}"
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
  done < <(find "$root" -type f -name '*.patch' -print | sort -V)
}

validate_script_tree project-scripts true
validate_script_tree project-scripts-additional false
validate_patch_tree patches
validate_patch_tree patches-additional

./scripts/ci-plan.sh >/dev/null
echo "Configuration is valid."


