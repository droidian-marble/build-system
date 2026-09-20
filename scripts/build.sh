#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
./scripts/validate.sh

additional_mode=false
requested=()
for arg in "$@"; do
  if [[ "$arg" == "--additional" ]]; then
    additional_mode=true
  else
    requested+=("$arg")
  fi
done

if $additional_mode && ((${#requested[@]} == 0)); then
  echo "usage: scripts/build.sh [--additional] [project ...]"
  exit 2
fi

REQUESTED=""
if ((${#requested[@]})); then
  selections=()
  for project in "${requested[@]}"; do
    if $additional_mode; then
      selections+=("$project-additional")
    else
      selections+=("$project")
    fi
  done
  REQUESTED="$(IFS=,; echo "${selections[*]}")"
fi

plan="$(./scripts/ci-plan.sh "$REQUESTED")"
mapfile -t selected_arches < <(jq -r '.include[].architecture' <<< "$plan" | sort -u)
actual_arch="$(dpkg --print-architecture)"

if ((${#selected_arches[@]} > 1)); then
  echo "Selected projects require multiple build architectures:"
  printf '  %s\n' "${selected_arches[@]}"
  echo "Build architecture groups separately inside their configured environments."
  exit 1
fi

for arch in "${selected_arches[@]}"; do
  if [[ "$arch" != "$actual_arch" ]]; then
    echo "Cannot build selected projects in this container: expected $arch, got $actual_arch"
    exit 1
  fi
done

while IFS=$'\t' read -r project additional; do
  [[ -n "$project" ]] || continue
  args=("$project")
  [[ "$additional" == true ]] && args+=(--additional)
  DEPENDENCY_OUTPUT_ROOT="$ROOT/dist" ./scripts/build-project.sh "${args[@]}"
done < <(jq -r '.include[] | [.name, (.additional | tostring)] | @tsv' <<< "$plan")
