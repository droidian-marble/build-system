#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/projects.json"
MATRIX_JSON="${MATRIX_JSON:?MATRIX_JSON is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

API_VERSION="2026-03-10"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
PACKAGE_DIR="$ROOT/droidian-packages-arm64"
APT_INPUT_DIR="$ROOT/apt-repo-input"
INDEX_FILE="$(mktemp)"
TMP_DIR="$(mktemp -d)"
trap 'rm -f "$INDEX_FILE"; rm -rf "$TMP_DIR"' EXIT

for cmd in curl jq unzip zip; do
  command -v "$cmd" >/dev/null || {
    echo "Missing command: $cmd"
    exit 1
  }
done

jq -e '
  type == "object"
  and (.include | type == "array")
  and all(.include[];
    (.name | type == "string" and length > 0) and
    ((.dependencies // []) | type == "array")
  )
' <<< "$MATRIX_JSON" >/dev/null

api_get() {
  curl \
    --fail \
    --silent \
    --show-error \
    --retry 3 \
    --retry-delay 2 \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL$1"
}

page=1
while :; do
  response="$(
    api_get "/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100&page=$page"
  )"

  jq -r '
    .artifacts[]
    | select(.expired | not)
    | [.name, (.id | tostring)]
    | @tsv
  ' <<< "$response" >> "$INDEX_FILE"

  count="$(jq '.artifacts | length' <<< "$response")"
  (( count == 100 )) || break
  ((page++))
done

mapfile -t selected < <(jq -r '.include[].name' <<< "$MATRIX_JSON")
if ((${#selected[@]} == 0)); then
  echo "created=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

declare -A artifact_ids adjacency visited publishable
for project in "${selected[@]}"; do
  artifact_ids["$project"]="$(
    awk -F '\t' -v name="project-$project" '$1 == name { id=$2 } END { print id }' "$INDEX_FILE"
  )"
  adjacency["$project"]=""
done

while IFS=$'\t' read -r project dependency; do
  [[ -n "$project" && -n "$dependency" ]] || continue
  adjacency["$project"]+=" $dependency"
  adjacency["$dependency"]+=" $project"
done < <(
  jq -r '
    .include[] as $project
    | ($project.dependencies // [])[]?
    | [$project.name, .]
    | @tsv
  ' <<< "$MATRIX_JSON"
)

for root in "${selected[@]}"; do
  [[ ${visited[$root]:-0} == 1 ]] && continue

  component=()
  stack=("$root")
  clean=true

  while ((${#stack[@]})); do
    last=$(( ${#stack[@]} - 1 ))
    project="${stack[$last]}"
    unset 'stack[$last]'

    [[ ${visited[$project]:-0} == 1 ]] && continue
    visited["$project"]=1
    component+=("$project")

    if [[ -z "${artifact_ids[$project]:-}" ]]; then
      clean=false
    fi

    for neighbor in ${adjacency[$project]:-}; do
      [[ ${visited[$neighbor]:-0} == 1 ]] || stack+=("$neighbor")
    done
  done

  if $clean; then
    for project in "${component[@]}"; do
      publishable["$project"]=1
    done
  else
    printf 'Skipping failed dependency component:'
    printf ' %s' "${component[@]}"
    printf '\n'
  fi
done

rm -rf "$PACKAGE_DIR" "$APT_INPUT_DIR" "$ROOT/droidian-packages-arm64.zip"
mkdir -p "$PACKAGE_DIR" "$APT_INPUT_DIR/repo-meta"

mapfile -t publishable_projects < <(
  for project in "${selected[@]}"; do
    [[ ${publishable[$project]:-0} == 1 ]] && printf '%s\n' "$project"
  done | sort
)

if ((${#publishable_projects[@]} == 0)); then
  rm -rf "$PACKAGE_DIR" "$APT_INPUT_DIR"
  echo "created=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

for project in "${publishable_projects[@]}"; do
  artifact_id="${artifact_ids[$project]}"
  archive="$TMP_DIR/$project.zip"
  destination="$PACKAGE_DIR/$project"

  mkdir -p "$destination"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-delay 2 \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "X-GitHub-Api-Version: $API_VERSION" \
    "$API_URL/repos/$GITHUB_REPOSITORY/actions/artifacts/$artifact_id/zip" \
    --output "$archive"
  unzip -q "$archive" -d "$destination"

  mkdir -p "$APT_INPUT_DIR/$project"
  while IFS= read -r -d '' deb; do
    cp -a "$deb" "$APT_INPUT_DIR/$project/"
  done < <(find "$destination" -type f -name '*.deb' -print0)
done

jq -r '.projects[].name' "$CONFIG" | sort -u > "$APT_INPUT_DIR/repo-meta/active-projects"
printf '%s\n' "${publishable_projects[@]}" > "$APT_INPUT_DIR/repo-meta/published-projects"

(
  cd "$ROOT"
  zip -rq droidian-packages-arm64.zip droidian-packages-arm64
)

echo "created=true" >> "$GITHUB_OUTPUT"
