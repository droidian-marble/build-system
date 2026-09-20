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
TMP_DIR="$(mktemp -d)"
INDEX_FILE="$TMP_DIR/artifacts.tsv"
trap 'rm -rf "$TMP_DIR"' EXIT

for cmd in curl jq unzip zip; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }
done

: > "$INDEX_FILE"
page=1
while :; do
  response="$(
    curl \
      --fail \
      --silent \
      --show-error \
      --retry 3 \
      --retry-delay 2 \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "X-GitHub-Api-Version: $API_VERSION" \
      "$API_URL/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100&page=$page"
  )"
  jq -r '.artifacts[] | select(.expired | not) | [.name, .id] | @tsv' <<< "$response" >> "$INDEX_FILE"
  count="$(jq '.artifacts | length' <<< "$response")"
  (( count == 100 )) || break
  ((page++))
done

node_key() {
  printf '%s|%s\n' "$1" "$2"
}

artifact_name() {
  printf 'project-%s' "$1"
  [[ "$2" == true ]] && printf '%s' '-additional'
  printf '\n'
}

mapfile -t selected_rows < <(jq -r '.include[] | [.name, (.additional | tostring)] | @tsv' <<< "$MATRIX_JSON")
if ((${#selected_rows[@]} == 0)); then
  echo "created=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

declare -A artifact_ids adjacency visited publishable node_project node_additional
selected_keys=()
for row in "${selected_rows[@]}"; do
  IFS=$'\t' read -r project additional <<< "$row"
  key="$(node_key "$project" "$additional")"
  selected_keys+=("$key")
  node_project["$key"]="$project"
  node_additional["$key"]="$additional"
  name="$(artifact_name "$project" "$additional")"
  artifact_ids["$key"]="$(awk -F '\t' -v name="$name" '$1 == name { id=$2 } END { print id }' "$INDEX_FILE")"
  adjacency["$key"]=""
done

while IFS=$'\t' read -r project additional dependency dep_additional; do
  [[ -n "$project" && -n "$dependency" ]] || continue
  key="$(node_key "$project" "$additional")"
  dep_key="$(node_key "$dependency" "$dep_additional")"
  adjacency["$key"]+=" $dep_key"
  adjacency["$dep_key"]+=" $key"
done < <(
  jq -r '
    .include[] as $project
    | ($project.dependencies // [])[]?
    | [$project.name, ($project.additional | tostring), .name, ((.additional // false) | tostring)]
    | @tsv
  ' <<< "$MATRIX_JSON"
)

for root in "${selected_keys[@]}"; do
  [[ ${visited[$root]:-0} == 1 ]] && continue

  component=()
  stack=("$root")
  clean=true

  while ((${#stack[@]})); do
    last=$(( ${#stack[@]} - 1 ))
    key="${stack[$last]}"
    unset 'stack[$last]'

    [[ ${visited[$key]:-0} == 1 ]] && continue
    visited["$key"]=1
    component+=("$key")

    if [[ -z "${artifact_ids[$key]:-}" ]]; then
      clean=false
    fi

    for neighbor in ${adjacency[$key]:-}; do
      [[ ${visited[$neighbor]:-0} == 1 ]] || stack+=("$neighbor")
    done
  done

  if $clean; then
    for key in "${component[@]}"; do
      publishable["$key"]=1
    done
  else
    printf 'Skipping failed dependency component:'
    for key in "${component[@]}"; do
      project="${node_project[$key]}"
      additional="${node_additional[$key]}"
      printf ' %s' "$project"
      [[ "$additional" == true ]] && printf '%s' '[additional]'
    done
    printf '\n'
  fi
done

rm -rf "$PACKAGE_DIR" "$APT_INPUT_DIR" "$ROOT/droidian-packages-arm64.zip"
mkdir -p "$PACKAGE_DIR" "$APT_INPUT_DIR/main/repo-meta" "$APT_INPUT_DIR/additional/repo-meta"

publishable_keys=()
for key in "${selected_keys[@]}"; do
  [[ ${publishable[$key]:-0} == 1 ]] && publishable_keys+=("$key")
done

if ((${#publishable_keys[@]} == 0)); then
  rm -rf "$PACKAGE_DIR" "$APT_INPUT_DIR"
  echo "created=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

for key in "${publishable_keys[@]}"; do
  project="${node_project[$key]}"
  additional="${node_additional[$key]}"
  artifact_id="${artifact_ids[$key]}"
  archive="$TMP_DIR/$(artifact_name "$project" "$additional").zip"
  component="main"
  destination="$PACKAGE_DIR/$project"
  if [[ "$additional" == true ]]; then
    component="additional"
    destination="$PACKAGE_DIR/additional/$project"
  fi

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

  mkdir -p "$APT_INPUT_DIR/$component/$project"
  while IFS= read -r -d '' deb; do
    cp -a "$deb" "$APT_INPUT_DIR/$component/$project/"
  done < <(find "$destination" -type f -name '*.deb' -print0)
done

jq -r '.projects[].name' "$CONFIG" | sort -u > "$APT_INPUT_DIR/main/repo-meta/active-projects"
jq -r '.projects[].name' "$CONFIG" | sort -u > "$APT_INPUT_DIR/additional/repo-meta/active-projects"

: > "$APT_INPUT_DIR/main/repo-meta/published-projects"
: > "$APT_INPUT_DIR/additional/repo-meta/published-projects"
for key in "${publishable_keys[@]}"; do
  project="${node_project[$key]}"
  if [[ "${node_additional[$key]}" == true ]]; then
    printf '%s\n' "$project" >> "$APT_INPUT_DIR/additional/repo-meta/published-projects"
  else
    printf '%s\n' "$project" >> "$APT_INPUT_DIR/main/repo-meta/published-projects"
  fi
done
sort -u -o "$APT_INPUT_DIR/main/repo-meta/published-projects" "$APT_INPUT_DIR/main/repo-meta/published-projects"
sort -u -o "$APT_INPUT_DIR/additional/repo-meta/published-projects" "$APT_INPUT_DIR/additional/repo-meta/published-projects"

(
  cd "$ROOT"
  zip -rq droidian-packages-arm64.zip droidian-packages-arm64
)

echo "created=true" >> "$GITHUB_OUTPUT"


