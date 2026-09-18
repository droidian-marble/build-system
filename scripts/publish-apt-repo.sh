#!/usr/bin/env bash
set -euo pipefail

INCOMING_DIR="${1:?usage: scripts/publish-apt-repo.sh <incoming-dir> <repository-dir>}"
REPO_DIR="${2:?usage: scripts/publish-apt-repo.sh <incoming-dir> <repository-dir>}"
SUITE="main"
COMPONENT="main"
MAX_VERSIONS=2
STATE_DIR="$REPO_DIR/.repo-state/projects"
META_DIR="$INCOMING_DIR/repo-meta"
ACTIVE_PROJECTS_FILE="$META_DIR/active-projects"
PUBLISHED_PROJECTS_FILE="$META_DIR/published-projects"

for cmd in apt-ftparchive dpkg dpkg-deb gzip gpg; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }
done

[[ -f "$ACTIVE_PROJECTS_FILE" ]] || {
  echo "Missing repository metadata: repo-meta/active-projects"
  exit 1
}
[[ -f "$PUBLISHED_PROJECTS_FILE" ]] || {
  echo "Missing repository metadata: repo-meta/published-projects"
  exit 1
}

mkdir -p "$REPO_DIR/pool" "$REPO_DIR/dists/$SUITE/$COMPONENT/binary-arm64" "$STATE_DIR"
shopt -s nullglob

mapfile -t active_projects < <(grep -Ev '^[[:space:]]*$' "$ACTIVE_PROJECTS_FILE" | sort -u)
mapfile -t published_projects < <(grep -Ev '^[[:space:]]*$' "$PUBLISHED_PROJECTS_FILE" | sort -u)

for project in "${active_projects[@]}" "${published_projects[@]}"; do
  [[ -z "$project" || "$project" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Invalid project name in repository metadata: $project"
    exit 1
  }
done

is_active_project() {
  local wanted="$1" project
  for project in "${active_projects[@]}"; do
    [[ "$project" == "$wanted" ]] && return 0
  done
  return 1
}

for project in "${published_projects[@]}"; do
  is_active_project "$project" || {
    echo "Published project is not present in active project metadata: $project"
    exit 1
  }
done

state_work="$(mktemp -d)"
trap 'rm -rf "$state_work"' EXIT
cp -a "$STATE_DIR"/. "$state_work"/ 2>/dev/null || true

incoming_debs=()
for project in "${published_projects[@]}"; do
  project_dir="$INCOMING_DIR/$project"
  project_packages=()

  if [[ -d "$project_dir" ]]; then
    while IFS= read -r -d '' deb; do
      arch="$(dpkg-deb -f "$deb" Architecture)"
      case "$arch" in
        arm64|all)
          incoming_debs+=("$deb")
          project_packages+=("$(dpkg-deb -f "$deb" Package)")
          ;;
        *)
          echo "Skipping unsupported architecture: $(basename "$deb") [$arch]"
          ;;
      esac
    done < <(find "$project_dir" -type f -name '*.deb' -print0)
  fi

  if ((${#project_packages[@]})); then
    printf '%s\n' "${project_packages[@]}" | sort -u > "$state_work/$project.packages"
  else
    : > "$state_work/$project.packages"
  fi
done

for manifest in "$state_work"/*.packages; do
  [[ -e "$manifest" ]] || continue
  project="$(basename "$manifest" .packages)"
  if ! is_active_project "$project"; then
    rm -f "$manifest"
  fi
done

old_claims="$(mktemp)"
new_claims="$(mktemp)"
trap 'rm -rf "$state_work"; rm -f "$old_claims" "$new_claims"' EXIT

collect_claims() {
  local dir="$1" output="$2" manifest
  : > "$output"
  for manifest in "$dir"/*.packages; do
    [[ -e "$manifest" ]] || continue
    grep -Ev '^[[:space:]]*$' "$manifest" >> "$output" || true
  done
  if [[ -s "$output" ]]; then
    sort -u "$output" -o "$output"
  fi
}

collect_claims "$STATE_DIR" "$old_claims"
collect_claims "$state_work" "$new_claims"

while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  if ! grep -Fxq "$package" "$new_claims"; then
    for deb in "$REPO_DIR"/pool/*.deb; do
      [[ -e "$deb" ]] || continue
      if [[ "$(dpkg-deb -f "$deb" Package)" == "$package" ]]; then
        echo "Removing unowned package: $package ($(basename "$deb"))"
        rm -f "$deb"
      fi
    done
  fi
done < "$old_claims"

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
cp -a "$state_work"/. "$STATE_DIR"/

for deb in "${incoming_debs[@]}"; do
  cp -f "$deb" "$REPO_DIR/pool/$(basename "$deb")"
done

mapfile -t package_names < <(
  for deb in "$REPO_DIR"/pool/*.deb; do
    [[ -e "$deb" ]] || continue
    dpkg-deb -f "$deb" Package
  done | sort -u
)

for package in "${package_names[@]}"; do
  versions=()
  for deb in "$REPO_DIR"/pool/*.deb; do
    [[ -e "$deb" ]] || continue
    [[ "$(dpkg-deb -f "$deb" Package)" == "$package" ]] || continue
    version="$(dpkg-deb -f "$deb" Version)"
    seen=false
    for existing in "${versions[@]:-}"; do
      if [[ "$existing" == "$version" ]]; then
        seen=true
        break
      fi
    done
    $seen || versions+=("$version")
  done

  sorted=()
  for version in "${versions[@]}"; do
    inserted=false
    for ((i = 0; i < ${#sorted[@]}; i++)); do
      if dpkg --compare-versions "$version" gt "${sorted[$i]}"; then
        sorted=("${sorted[@]:0:$i}" "$version" "${sorted[@]:$i}")
        inserted=true
        break
      fi
    done
    $inserted || sorted+=("$version")
  done

  keep=("${sorted[@]:0:$MAX_VERSIONS}")
  for deb in "$REPO_DIR"/pool/*.deb; do
    [[ -e "$deb" ]] || continue
    [[ "$(dpkg-deb -f "$deb" Package)" == "$package" ]] || continue
    version="$(dpkg-deb -f "$deb" Version)"
    keep_this=false
    for kept_version in "${keep[@]}"; do
      if [[ "$version" == "$kept_version" ]]; then
        keep_this=true
        break
      fi
    done
    if ! $keep_this; then
      echo "Pruning $package $version"
      rm -f "$deb"
    fi
  done
done

packages_dir="$REPO_DIR/dists/$SUITE/$COMPONENT/binary-arm64"
(
  cd "$REPO_DIR"
  apt-ftparchive packages pool > "dists/$SUITE/$COMPONENT/binary-arm64/Packages"
)
gzip -9 -c "$packages_dir/Packages" > "$packages_dir/Packages.gz"

apt-ftparchive \
  -o APT::FTPArchive::Release::Origin="Droidian Patch Builder" \
  -o APT::FTPArchive::Release::Label="Droidian Patch Builder" \
  -o APT::FTPArchive::Release::Suite="$SUITE" \
  -o APT::FTPArchive::Release::Codename="$SUITE" \
  -o APT::FTPArchive::Release::Architectures="arm64" \
  -o APT::FTPArchive::Release::Components="$COMPONENT" \
  -o APT::FTPArchive::Release::Description="Droidian ARM64 package repository" \
  release "$REPO_DIR/dists/$SUITE" > "$REPO_DIR/dists/$SUITE/Release"

signed=false
if [[ -n "${APT_REPO_GPG_PRIVATE_KEY:-}" ]]; then
  gnupg_home="$(mktemp -d)"
  chmod 700 "$gnupg_home"
  export GNUPGHOME="$gnupg_home"
  trap 'rm -rf "$state_work"; rm -f "$old_claims" "$new_claims"; rm -rf "$gnupg_home"' EXIT

  printf '%s' "$APT_REPO_GPG_PRIVATE_KEY" | gpg --batch --import
  fingerprint="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ -n "$fingerprint" ]] || { echo "No secret GPG key found after import"; exit 1; }

  gpg --batch --yes --export "$fingerprint" > "$REPO_DIR/repo-key.gpg"

  sign_args=(--batch --yes --local-user "$fingerprint")
  if [[ -n "${APT_REPO_GPG_PASSPHRASE:-}" ]]; then
    sign_args+=(--pinentry-mode loopback --passphrase "$APT_REPO_GPG_PASSPHRASE")
  fi

  gpg "${sign_args[@]}" --clearsign \
    --output "$REPO_DIR/dists/$SUITE/InRelease" \
    "$REPO_DIR/dists/$SUITE/Release"
  gpg "${sign_args[@]}" --armor --detach-sign \
    --output "$REPO_DIR/dists/$SUITE/Release.gpg" \
    "$REPO_DIR/dists/$SUITE/Release"
  signed=true
else
  rm -f "$REPO_DIR/repo-key.gpg" "$REPO_DIR/dists/$SUITE/InRelease" "$REPO_DIR/dists/$SUITE/Release.gpg"
fi

package_count="$(find "$REPO_DIR/pool" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')"
cat > "$REPO_DIR/index.html" <<EOF_HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Droidian Package Repository</title></head>
<body>
<h1>Droidian Package Repository</h1>
<p>Suite: <code>$SUITE</code></p>
<p>Component: <code>$COMPONENT</code></p>
<p>Architecture: <code>arm64</code></p>
<p>Packages: <code>$package_count</code></p>
<p>Signed: <code>$signed</code></p>
</body>
</html>
EOF_HTML
: > "$REPO_DIR/.nojekyll"

echo "APT repository generated: suite=$SUITE component=$COMPONENT packages=$package_count signed=$signed"
