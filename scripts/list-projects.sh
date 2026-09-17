#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED="${1:-}"
cd "$ROOT"
if [[ -z "$REQUESTED" ]]; then
  jq -r '.projects[] | select(.enabled) | .name' projects.json
  exit 0
fi
IFS=',' read -r -a names <<< "$REQUESTED"
for name in "${names[@]}"; do
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  [[ -n "$name" ]] || continue
  if ! jq -e --arg name "$name" '.projects[] | select(.name == $name)' projects.json >/dev/null; then
    echo "Unknown project: $name"
    exit 1
  fi
  printf '%s\n' "$name"
done
