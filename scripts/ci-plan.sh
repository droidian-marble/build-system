#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED="${1:-}"
MAX_LEVEL=7
cd "$ROOT"

declare -A exists selected visiting visited depth_cache
mapfile -t all_projects < <(jq -r '.projects[].name' projects.json)
for project in "${all_projects[@]}"; do
  exists["$project"]=1
done

deps_of() {
  jq -r --arg name "$1" \
    '.projects[] | select(.name == $name) | .dependencies[]?.project' \
    projects.json
}

select_with_dependencies() {
  local project="$1" dep
  [[ ${exists[$project]:-0} == 1 ]] || {
    echo "Unknown project: $project" >&2
    exit 1
  }
  [[ ${selected[$project]:-0} == 1 ]] && return
  selected["$project"]=1
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && select_with_dependencies "$dep"
  done < <(deps_of "$project")
}

if [[ -n "$REQUESTED" ]]; then
  IFS=',' read -r -a requested <<< "$REQUESTED"
  for project in "${requested[@]}"; do
    project="${project#"${project%%[![:space:]]*}"}"
    project="${project%"${project##*[![:space:]]}"}"
    [[ -n "$project" ]] && select_with_dependencies "$project"
  done
else
  while IFS= read -r project; do
    [[ -n "$project" ]] && select_with_dependencies "$project"
  done < <(jq -r '.projects[] | select(.enabled) | .name' projects.json)
fi

depth_of() {
  local project="$1" dep dep_depth max=-1
  if [[ -n "${depth_cache[$project]+x}" ]]; then
    printf '%s\n' "${depth_cache[$project]}"
    return
  fi
  [[ ${visiting[$project]:-0} == 1 ]] && {
    echo "Dependency cycle detected at: $project" >&2
    exit 1
  }
  visiting["$project"]=1
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    dep_depth="$(depth_of "$dep")"
    (( dep_depth > max )) && max="$dep_depth"
  done < <(deps_of "$project")
  visiting["$project"]=0
  depth_cache["$project"]=$((max + 1))
  printf '%s\n' "${depth_cache[$project]}"
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for project in "${!selected[@]}"; do
  level="$(depth_of "$project")"
  (( level <= MAX_LEVEL )) || {
    echo "Dependency depth for $project is $level; workflow supports levels 0-$MAX_LEVEL" >&2
    exit 1
  }

  jq -c \
    --arg name "$project" \
    --argjson level "$level" '
      . as $root
      | ($root.projects[] | select(.name == $name)) as $project
      | ($project.architecture // $root.defaults.architecture // "arm64") as $arch
      | {
          name: $project.name,
          level: $level,
          architecture: $arch,
          image: ($project.image // $root.defaults.images[$arch]),
          runner: ($project.runner // $root.defaults.runners[$arch])
        }
    ' projects.json >> "$tmp"
done

jq -s 'sort_by(.level, .name)' "$tmp"
