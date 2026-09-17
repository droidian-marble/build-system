#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/validate.sh
if (($#)); then requested=("$@"); else mapfile -t requested < <(./scripts/list-projects.sh); fi
if ((${#requested[@]} == 0)); then echo "No projects selected. Enable projects in projects.json or pass project names explicitly."; exit 0; fi
declare -A state result
declare -a order
deps_of() { jq -r --arg name "$1" '.projects[] | select(.name == $name) | .dependencies[]?.project' projects.json; }
visit() {
  local project="$1" dep current="${state[$1]:-0}"
  [[ "$current" == 2 ]] && return
  [[ "$current" == 1 ]] && { echo "Dependency cycle reached at: $project"; exit 1; }
  state[$project]=1
  while IFS= read -r dep; do [[ -n "$dep" ]] && visit "$dep"; done < <(deps_of "$project")
  state[$project]=2
  order+=("$project")
}
for project in "${requested[@]}"; do
  jq -e --arg name "$project" '.projects[] | select(.name == $name)' projects.json >/dev/null || { echo "Unknown project: $project"; exit 1; }
  visit "$project"
done
mkdir -p .work
: > .work/build-status.tsv
failures=0
for project in "${order[@]}"; do
  blocked_by=()
  while IFS= read -r dep; do [[ -n "$dep" && "${result[$dep]:-failed}" != success ]] && blocked_by+=("$dep"); done < <(deps_of "$project")
  if ((${#blocked_by[@]})); then
    echo "===== $project: BLOCKED by ${blocked_by[*]} ====="
    result[$project]=blocked
    printf '%s\tblocked\t%s\n' "$project" "${blocked_by[*]}" >> .work/build-status.tsv
    failures=1
    continue
  fi
  echo "===== $project ====="
  if ./scripts/build-one-project.sh "$project"; then
    result[$project]=success
    printf '%s\tsuccess\t-\n' "$project" >> .work/build-status.tsv
  else
    result[$project]=failed
    printf '%s\tfailed\t-\n' "$project" >> .work/build-status.tsv
    failures=1
  fi
done
echo "===== BUILD SUMMARY ====="
if command -v column >/dev/null; then column -t -s $'\t' .work/build-status.tsv; else cat .work/build-status.tsv; fi
exit "$failures"
