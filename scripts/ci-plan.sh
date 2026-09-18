#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED="${1:-}"
cd "$ROOT"

declare -A exists selected visiting depth_cache

mapfile -t all_projects < <(jq -r '.projects[].name' projects.json)
for project in "${all_projects[@]}"; do
  exists["$project"]=1
done

deps_of() {
  jq -r --arg name "$1" '
    .projects[]
    | select(.name == $name)
    | .dependencies[]?.project
  ' projects.json
}

select_with_dependencies() {
  local project="$1" dependency

  [[ ${exists[$project]:-0} == 1 ]] || {
    echo "Unknown project: $project" >&2
    exit 1
  }

  [[ ${selected[$project]:-0} == 1 ]] && return
  selected["$project"]=1

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] && select_with_dependencies "$dependency"
  done < <(deps_of "$project")
}

depth_of() {
  local project="$1" dependency dependency_depth max=-1

  if [[ -n "${depth_cache[$project]+x}" ]]; then
    printf '%s\n' "${depth_cache[$project]}"
    return
  fi

  [[ ${visiting[$project]:-0} == 1 ]] && {
    echo "Dependency cycle detected at: $project" >&2
    exit 1
  }

  visiting["$project"]=1

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    dependency_depth="$(depth_of "$dependency")"
    (( dependency_depth > max )) && max="$dependency_depth"
  done < <(deps_of "$project")

  visiting["$project"]=0
  depth_cache["$project"]=$((max + 1))
  printf '%s\n' "${depth_cache[$project]}"
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
  done < <(
    jq -r '.projects[] | select(.enabled) | .name' projects.json
  )
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for project in "${!selected[@]}"; do
  depth="$(depth_of "$project")"

  jq -c \
    --arg name "$project" \
    --argjson depth "$depth" '
      . as $root
      | ($root.projects[] | select(.name == $name)) as $project
      | ($project.architecture // $root.defaults.architecture // "arm64") as $arch
      | {
          name: $project.name,
          depth: $depth,
          architecture: $arch,
          image: ($project.image // $root.defaults.images[$arch]),
          runner: ($project.runner // $root.defaults.runners[$arch]),
          dependencies: [($project.dependencies[]?.project)],
          has_dependencies: (($project.dependencies // []) | length > 0)
        }
    ' projects.json >> "$tmp"
done

jq -cs '
  sort_by(.depth, .name)
  | map(del(.depth))
  | {include: .}
' "$tmp"
