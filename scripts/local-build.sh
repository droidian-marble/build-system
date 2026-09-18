#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/projects.json"
LOCAL_WORK_ROOT="$ROOT/.local-work"
LOCAL_OUTPUT_ROOT="$ROOT/local-output"
cd "$ROOT"

if (($# != 1)); then
  echo "usage: scripts/local-build.sh <project>"
  exit 2
fi

TARGET="$1"

command -v jq >/dev/null || {
  echo "Missing command: jq"
  exit 1
}

./scripts/validate.sh

jq -e --arg name "$TARGET" '.projects[] | select(.name == $name)' "$CONFIG" >/dev/null || {
  echo "Unknown project: $TARGET"
  exit 1
}

if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
  runtime="$CONTAINER_RUNTIME"
  command -v "$runtime" >/dev/null || {
    echo "Container runtime not found: $runtime"
    exit 1
  }
elif command -v podman >/dev/null; then
  runtime="podman"
elif command -v docker >/dev/null; then
  runtime="docker"
else
  echo "Missing container runtime: install podman or docker"
  exit 1
fi

plan="$(./scripts/ci-plan.sh "$TARGET")"

rm -rf "$LOCAL_WORK_ROOT"
mkdir -p "$LOCAL_WORK_ROOT" "$LOCAL_OUTPUT_ROOT"

while IFS= read -r project; do
  [[ -n "$project" ]] || continue
  rm -rf "$LOCAL_OUTPUT_ROOT/$project"
done < <(jq -r '.include[].name' <<< "$plan")

while IFS=$'\t' read -r project architecture image; do
  [[ -n "$project" && -n "$architecture" && -n "$image" ]] || continue

  echo "==> Local build $project"
  echo "    image: $image"

  "$runtime" run --rm --pull=always \
    --platform "linux/$architecture" \
    --volume "$ROOT:/workspace" \
    --workdir /workspace \
    --env DEBIAN_FRONTEND=noninteractive \
    --env LOCAL_BUILD_PROJECT="$project" \
    --env LOCAL_WORK_ROOT=/workspace/.local-work \
    --env LOCAL_OUTPUT_ROOT=/workspace/local-output \
    "$image" \
    /bin/bash -lc '
      set -euo pipefail
      apt-get update
      apt-get install -y --no-install-recommends jq curl ca-certificates unzip
      DEPENDENCY_OUTPUT_ROOT="$LOCAL_OUTPUT_ROOT" ./scripts/local-build-project.sh "$LOCAL_BUILD_PROJECT"
    '
done < <(
  jq -r '.include[] | [.name, .architecture, .image] | @tsv' <<< "$plan"
)
