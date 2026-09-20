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

node_key() {
  printf '%s|%s\n' "$1" "$2"
}

split_key() {
  NODE_PROJECT="${1%|*}"
  NODE_ADDITIONAL="${1##*|}"
}

deps_of() {
  local key="$1"
  split_key "$key"
  jq -r --arg name "$NODE_PROJECT" --argjson additional "$NODE_ADDITIONAL" '
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
    | "\(.project)|\((.additional // false) | tostring)"
  ' projects.json
}

select_with_dependencies() {
  local key="$1" dependency
  split_key "$key"

  [[ ${exists[$NODE_PROJECT]:-0} == 1 ]] || {
    echo "Unknown project: $NODE_PROJECT" >&2
    exit 1
  }
  [[ ${selected[$key]:-0} == 1 ]] && return
  selected["$key"]=1

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] && select_with_dependencies "$dependency"
  done < <(deps_of "$key")
}

depth_of() {
  local key="$1" dependency dependency_depth max=-1

  if [[ -n "${depth_cache[$key]+x}" ]]; then
    printf '%s\n' "${depth_cache[$key]}"
    return
  fi

  [[ ${visiting[$key]:-0} == 1 ]] && {
    split_key "$key"
    label="$NODE_PROJECT"
    [[ "$NODE_ADDITIONAL" == true ]] && label+="-additional"
    echo "Dependency cycle detected at: $label" >&2
    exit 1
  }

  visiting["$key"]=1

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    dependency_depth="$(depth_of "$dependency")"
    (( dependency_depth > max )) && max="$dependency_depth"
  done < <(deps_of "$key")

  visiting["$key"]=0
  depth_cache["$key"]=$((max + 1))
  printf '%s\n' "${depth_cache[$key]}"
}

if [[ -n "$REQUESTED" ]]; then
  IFS=',' read -r -a requested <<< "$REQUESTED"

  for token in "${requested[@]}"; do
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -n "$token" ]] || continue

    if [[ ${exists[$token]:-0} == 1 ]]; then
      select_with_dependencies "$(node_key "$token" false)"
    elif [[ "$token" == *-additional && ${exists[${token%-additional}]:-0} == 1 ]]; then
      select_with_dependencies "$(node_key "${token%-additional}" true)"
    else
      echo "Unknown project selection: $token" >&2
      exit 1
    fi
  done
else
  while IFS=$'\t' read -r project base additional; do
    [[ "$base" == true ]] && select_with_dependencies "$(node_key "$project" false)"
    [[ "$additional" == true ]] && select_with_dependencies "$(node_key "$project" true)"
  done < <(jq -r '.projects[] | [.name, (.base // false), (.additional // false)] | @tsv' projects.json)
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for key in "${!selected[@]}"; do
  split_key "$key"
  project="$NODE_PROJECT"
  additional="$NODE_ADDITIONAL"
  depth="$(depth_of "$key")"

  jq -c \
    --arg name "$project" \
    --argjson additional "$additional" \
    --argjson depth "$depth" '
      def dependencies_for($project; $additional):
        if $additional then
          ($project["dependencies-additional"] // []) as $overrides
          | ($overrides | map(.project)) as $override_projects
          | ([($project.dependencies // [])[] | select(.project as $dep | ($override_projects | index($dep)) == null)] + $overrides)
        else
          ($project.dependencies // [])
        end;
      . as $root
      | ($root.projects[] | select(.name == $name)) as $project
      | ($project.architecture // $root.defaults.architecture // "arm64") as $arch
      | dependencies_for($project; $additional) as $dependencies
      | {
          name: $project.name,
          additional: $additional,
          depth: $depth,
          architecture: $arch,
          image: ($project.image // $root.defaults.images[$arch]),
          runner: ($project.runner // $root.defaults.runners[$arch]),
          container_options: ($project.container_options // ""),
          dependencies: [($dependencies[]? | {name: .project, additional: (.additional // false)})],
          has_dependencies: (($dependencies | length) > 0)
        }
    ' projects.json >> "$tmp"
done

jq -cs '
  sort_by(.depth, .name, .additional)
  | map(del(.depth))
  | {include: .}
' "$tmp"


