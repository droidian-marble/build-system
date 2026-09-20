#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${DEPENDENCY_OUTPUT_ROOT:?DEPENDENCY_OUTPUT_ROOT is required}"

DEPENDENCIES_JSON="${DEPENDENCIES_JSON:-[]}"
POLL_INTERVAL="${DEPENDENCY_POLL_INTERVAL:-30}"
TIMEOUT_SECONDS="${DEPENDENCY_WAIT_TIMEOUT:-21600}"
API_VERSION="2026-03-10"
API_URL="${GITHUB_API_URL:-https://api.github.com}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for cmd in curl jq unzip; do
  command -v "$cmd" >/dev/null || {
    echo "Missing command: $cmd"
    exit 1
  }
done

jq -e '
  type == "array"
  and all(.[];
    type == "object"
    and (.name | type == "string" and length > 0)
    and ((.additional // false) | type == "boolean")
  )
' <<< "$DEPENDENCIES_JSON" >/dev/null

if [[ "$(jq 'length' <<< "$DEPENDENCIES_JSON")" == "0" ]]; then
  exit 0
fi

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

list_run_jobs() {
  local page=1 response count combined='[]'

  while :; do
    response="$(api_get "/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=latest&per_page=100&page=$page")"
    combined="$(jq -cn --argjson left "$combined" --argjson right "$(jq '.jobs' <<< "$response")" '$left + $right')"
    count="$(jq '.jobs | length' <<< "$response")"
    (( count == 100 )) || break
    ((page++))
  done

  printf '%s\n' "$combined"
}

list_run_artifacts() {
  local page=1 response count combined='[]'

  while :; do
    response="$(api_get "/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100&page=$page")"
    combined="$(jq -cn --argjson left "$combined" --argjson right "$(jq '.artifacts' <<< "$response")" '$left + $right')"
    count="$(jq '.artifacts | length' <<< "$response")"
    (( count == 100 )) || break
    ((page++))
  done

  printf '%s\n' "$combined"
}

dependency_artifact_name() {
  local project="$1" additional="$2"
  printf 'project-%s' "$project"
  [[ "$additional" == true ]] && printf '%s' '-additional'
  printf '\n'
}

dependency_job_name() {
  local project="$1" additional="$2"
  printf 'Build %s' "$project"
  [[ "$additional" == true ]] && printf ' [additional]'
  printf '\n'
}

download_artifact() {
  local dependency="$1" additional="$2" artifact_id="$3"
  local artifact_name archive destination
  artifact_name="$(dependency_artifact_name "$dependency" "$additional")"
  archive="$tmp_dir/$artifact_name.zip"
  destination="$DEPENDENCY_OUTPUT_ROOT/$artifact_name"

  rm -rf "$destination"
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
  rm -f "$archive"
}

started="$SECONDS"
while :; do
  jobs="$(list_run_jobs)"
  pending=false

  while IFS=$'\t' read -r dependency additional; do
    job_name="$(dependency_job_name "$dependency" "$additional")"
    job="$(
      jq -c --arg name "$job_name" '
        [.[] | select(.name == $name)]
        | last // empty
      ' <<< "$jobs"
    )"

    if [[ -z "$job" ]]; then
      pending=true
      continue
    fi

    status="$(jq -r '.status' <<< "$job")"
    conclusion="$(jq -r '.conclusion // ""' <<< "$job")"

    if [[ "$status" != "completed" ]]; then
      pending=true
      continue
    fi

    if [[ "$conclusion" != "success" ]]; then
      echo "Dependency failed: $dependency$([[ "$additional" == true ]] && printf '%s' ' [additional]') ($conclusion)"
      exit 1
    fi
  done < <(jq -r '.[] | [.name, ((.additional // false) | tostring)] | @tsv' <<< "$DEPENDENCIES_JSON")

  $pending || break

  if (( SECONDS - started >= TIMEOUT_SECONDS )); then
    echo "Timed out resolving dependency jobs"
    exit 1
  fi

  sleep "$POLL_INTERVAL"
done

while :; do
  artifacts="$(list_run_artifacts)"
  missing=false
  declare -A artifact_ids=()

  while IFS=$'\t' read -r dependency additional; do
    artifact_name="$(dependency_artifact_name "$dependency" "$additional")"
    artifact_id="$(
      jq -r --arg name "$artifact_name" '
        [.[] | select(.name == $name and (.expired | not))]
        | last
        | .id // empty
      ' <<< "$artifacts"
    )"

    key="$dependency|$additional"
    if [[ -z "$artifact_id" ]]; then
      missing=true
    else
      artifact_ids["$key"]="$artifact_id"
    fi
  done < <(jq -r '.[] | [.name, ((.additional // false) | tostring)] | @tsv' <<< "$DEPENDENCIES_JSON")

  $missing || break

  if (( SECONDS - started >= TIMEOUT_SECONDS )); then
    echo "Timed out resolving dependency artifacts"
    exit 1
  fi

  sleep 5
done

while IFS=$'\t' read -r dependency additional; do
  download_artifact "$dependency" "$additional" "${artifact_ids[$dependency|$additional]}"
done < <(jq -r '.[] | [.name, ((.additional // false) | tostring)] | @tsv' <<< "$DEPENDENCIES_JSON")
