#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/projects.json"
LOCAL_WORK_ROOT="$ROOT/.local-work"
LOCAL_OUTPUT_ROOT="$ROOT/local-output"
cd "$ROOT"

additional_mode=false
requested=()
for arg in "$@"; do
  if [[ "$arg" == "--additional" ]]; then
    additional_mode=true
  else
    requested+=("$arg")
  fi
done

if ((${#requested[@]} != 1)); then
  echo "usage: scripts/local-build.sh [--additional] <project>"
  exit 2
fi

TARGET="${requested[0]}"
$additional_mode && TARGET+="-additional"

command -v jq >/dev/null || {
  echo "Missing command: jq"
  exit 1
}

./scripts/validate.sh

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

while IFS=$'\t' read -r project additional; do
  variant="base"
  [[ "$additional" == true ]] && variant="additional"
  rm -rf "$LOCAL_OUTPUT_ROOT/$project/$variant"
done < <(jq -r '.include[] | [.name, (.additional | tostring)] | @tsv' <<< "$plan")

while IFS=$'\t' read -r project additional architecture image container_options; do
  [[ -n "$project" && -n "$architecture" && -n "$image" ]] || continue

  label="$project"
  [[ "$additional" == true ]] && label+=" [additional]"
  echo "==> Local build $label"
  echo "    image: $image"

  container_args=()
  if [[ -n "$container_options" ]]; then
    read -r -a container_args <<< "$container_options"
  fi

  "$runtime" run --rm --pull=always "${container_args[@]}" \
    --platform "linux/$architecture" \
    --volume "$ROOT:/workspace" \
    --workdir /workspace \
    --env DEBIAN_FRONTEND=noninteractive \
    --env LOCAL_BUILD_PROJECT="$project" \
    --env LOCAL_BUILD_ADDITIONAL="$additional" \
    --env LOCAL_WORK_ROOT=/workspace/.local-work \
    --env LOCAL_OUTPUT_ROOT=/workspace/local-output \
    "$image" \
    /bin/bash -lc '
      set -euo pipefail
      apt-get update
      apt-get install -y --no-install-recommends jq curl ca-certificates unzip
      args=("$LOCAL_BUILD_PROJECT")
      [[ "$LOCAL_BUILD_ADDITIONAL" == true ]] && args+=(--additional)
      DEPENDENCY_OUTPUT_ROOT="$LOCAL_OUTPUT_ROOT" ./scripts/local-build-project.sh "${args[@]}"
    '
done < <(jq -r '.include[] | [.name, (.additional | tostring), .architecture, .image, (.container_options // "")] | @tsv' <<< "$plan")


