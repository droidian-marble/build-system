#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED="${1:-}"
cd "$ROOT"
mapfile -t selected < <(./scripts/list-projects.sh "$REQUESTED")
((${#selected[@]})) || exit 0
depends_on() {
  local root="$1" needle="$2" dep
  while IFS= read -r dep; do
    [[ "$dep" == "$needle" ]] && return 0
    depends_on "$dep" "$needle" && return 0
  done < <(jq -r --arg name "$root" '.projects[] | select(.name == $name) | .dependencies[]?.project' projects.json)
  return 1
}
for candidate in "${selected[@]}"; do
  is_dependency=false
  for other in "${selected[@]}"; do
    [[ "$other" == "$candidate" ]] && continue
    if depends_on "$other" "$candidate"; then is_dependency=true; break; fi
  done
  $is_dependency || printf '%s\n' "$candidate"
done
