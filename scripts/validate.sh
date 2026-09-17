#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v jq >/dev/null
jq -e '
  (.defaults | type == "object") and
  (.defaults.image | type == "string" and length > 0) and
  (.projects | type == "array") and
  ([.projects[].name] | length == (unique | length)) and
  all(.projects[];
    (.name | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.enabled | type == "boolean") and
    (.repo | type == "string" and length > 0) and
    (.branch | type == "string" and length > 0) and
    ((.apt_packages // []) | type == "array" and all(.[]; type == "string" and length > 0)) and
    ((.before_build // "") | type == "string") and
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
for name in "${names[@]}"; do exists[$name]=1; done
for name in "${names[@]}"; do
  while IFS= read -r dep; do [[ ${exists[$dep]:-0} == 1 ]] || { echo "Unknown dependency: $name -> $dep"; exit 1; }; done < <(jq -r --arg name "$name" '.projects[] | select(.name == $name) | .dependencies[]?.project' projects.json)
done
check_cycle() {
  local project="$1" dep
  [[ ${visited[$project]:-0} == 1 ]] && return
  [[ ${visiting[$project]:-0} == 1 ]] && { echo "Dependency cycle detected at: $project"; exit 1; }
  visiting[$project]=1
  while IFS= read -r dep; do [[ -n "$dep" ]] && check_cycle "$dep"; done < <(jq -r --arg name "$project" '.projects[] | select(.name == $name) | .dependencies[]?.project' projects.json)
  visiting[$project]=0
  visited[$project]=1
}
for name in "${names[@]}"; do check_cycle "$name"; done
while IFS= read -r patch; do
  base="$(basename "$patch")"
  [[ "$base" =~ ^[0-9]{4}-.+\.patch$ ]] || { echo "Invalid active patch name: $patch (expected 0001-description.patch)"; exit 1; }
done < <(find patches -type f -name '*.patch' -print | sort -V)
echo "Configuration is valid."
