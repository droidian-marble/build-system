#!/usr/bin/env bash
set -euo pipefail

INCOMING_DIR="${1:?usage: scripts/publish-apt-repo.sh <incoming-dir> <repository-dir>}"
REPO_DIR="${2:?usage: scripts/publish-apt-repo.sh <incoming-dir> <repository-dir>}"
SUITES=(main additional)
COMPONENT="main"
MAX_VERSIONS=2

for cmd in apt-ftparchive dpkg dpkg-deb gzip gpg; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }
done

validate_project_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

mkdir -p "$REPO_DIR/pool/main" "$REPO_DIR/.repo-state/main"
if [[ -d "$REPO_DIR/.repo-state/projects" && ! -d "$REPO_DIR/.repo-state/main/projects" ]]; then
  mv "$REPO_DIR/.repo-state/projects" "$REPO_DIR/.repo-state/main/projects"
fi
shopt -s nullglob
legacy_debs=("$REPO_DIR"/pool/*.deb)
if ((${#legacy_debs[@]})); then
  mv "${legacy_debs[@]}" "$REPO_DIR/pool/main/"
fi

# Remove the obsolete one-suite/two-component layout if it was published by an older revision.
rm -rf "$REPO_DIR/dists/main/additional"

process_suite() {
  local suite="$1"
  local suite_incoming="$INCOMING_DIR/$suite"
  local meta_dir="$suite_incoming/repo-meta"
  local active_projects_file="$meta_dir/active-projects"
  local published_projects_file="$meta_dir/published-projects"
  local state_dir="$REPO_DIR/.repo-state/$suite/projects"
  local state_work old_claims new_claims project project_dir manifest package deb arch version

  [[ -f "$active_projects_file" ]] || {
    echo "Missing repository metadata: $suite/repo-meta/active-projects"
    exit 1
  }
  [[ -f "$published_projects_file" ]] || {
    echo "Missing repository metadata: $suite/repo-meta/published-projects"
    exit 1
  }

  mkdir -p "$REPO_DIR/pool/$suite" "$REPO_DIR/dists/$suite/$COMPONENT/binary-arm64" "$state_dir"
  shopt -s nullglob

  mapfile -t active_projects < <(grep -Ev '^[[:space:]]*$' "$active_projects_file" | sort -u)
  mapfile -t published_projects < <(grep -Ev '^[[:space:]]*$' "$published_projects_file" | sort -u)

  for project in "${active_projects[@]}" "${published_projects[@]}"; do
    [[ -z "$project" ]] || validate_project_name "$project" || {
      echo "Invalid project name in $suite repository metadata: $project"
      exit 1
    }
  done

  is_active_project() {
    local wanted="$1" candidate
    for candidate in "${active_projects[@]}"; do
      [[ "$candidate" == "$wanted" ]] && return 0
    done
    return 1
  }

  for project in "${published_projects[@]}"; do
    is_active_project "$project" || {
      echo "Published project is not present in $suite active project metadata: $project"
      exit 1
    }
  done

  state_work="$(mktemp -d)"
  old_claims="$(mktemp)"
  new_claims="$(mktemp)"
  if [[ -d "$state_dir" ]]; then
    cp -a "$state_dir"/. "$state_work"/
  fi

  incoming_debs=()
  for project in "${published_projects[@]}"; do
    project_dir="$suite_incoming/$project"
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

    if ((${#project_packages[@]} == 0)); then
      echo "Published project contains no arm64/all .deb packages: $suite/$project"
      exit 1
    fi
    printf '%s\n' "${project_packages[@]}" | sort -u > "$state_work/$project.packages"
  done

  for manifest in "$state_work"/*.packages; do
    [[ -e "$manifest" ]] || continue
    project="$(basename "$manifest" .packages)"
    if ! is_active_project "$project"; then
      rm -f "$manifest"
    fi
  done

  collect_claims() {
    local dir="$1" output="$2" item
    : > "$output"
    for item in "$dir"/*.packages; do
      [[ -e "$item" ]] || continue
      grep -Ev '^[[:space:]]*$' "$item" >> "$output" || true
    done
    if [[ -s "$output" ]]; then
      sort -u "$output" -o "$output"
    fi
  }

  collect_claims "$state_dir" "$old_claims"
  collect_claims "$state_work" "$new_claims"

  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if ! grep -Fxq "$package" "$new_claims"; then
      for deb in "$REPO_DIR"/pool/"$suite"/*.deb; do
        [[ -e "$deb" ]] || continue
        if [[ "$(dpkg-deb -f "$deb" Package)" == "$package" ]]; then
          echo "Removing unowned $suite package: $package ($(basename "$deb"))"
          rm -f "$deb"
        fi
      done
    fi
  done < "$old_claims"

  rm -rf "$state_dir"
  mkdir -p "$state_dir"
  cp -a "$state_work"/. "$state_dir"/

  for deb in "${incoming_debs[@]}"; do
    cp -f "$deb" "$REPO_DIR/pool/$suite/$(basename "$deb")"
  done

  mapfile -t package_names < <(
    for deb in "$REPO_DIR"/pool/"$suite"/*.deb; do
      [[ -e "$deb" ]] || continue
      dpkg-deb -f "$deb" Package
    done | sort -u
  )

  for package in "${package_names[@]}"; do
    versions=()
    for deb in "$REPO_DIR"/pool/"$suite"/*.deb; do
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
    for deb in "$REPO_DIR"/pool/"$suite"/*.deb; do
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
        echo "Pruning $suite $package $version"
        rm -f "$deb"
      fi
    done
  done

  packages_dir="$REPO_DIR/dists/$suite/$COMPONENT/binary-arm64"
  (
    cd "$REPO_DIR"
    apt-ftparchive packages "pool/$suite" > "dists/$suite/$COMPONENT/binary-arm64/Packages"
  )
  gzip -9 -c "$packages_dir/Packages" > "$packages_dir/Packages.gz"

  rm -rf "$state_work"
  rm -f "$old_claims" "$new_claims"
}

for suite in "${SUITES[@]}"; do
  process_suite "$suite"
done

for suite in "${SUITES[@]}"; do
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Droidian Patch Builder" \
    -o APT::FTPArchive::Release::Label="Droidian Patch Builder" \
    -o APT::FTPArchive::Release::Suite="$suite" \
    -o APT::FTPArchive::Release::Codename="$suite" \
    -o APT::FTPArchive::Release::Architectures="arm64" \
    -o APT::FTPArchive::Release::Components="$COMPONENT" \
    -o APT::FTPArchive::Release::Description="Droidian ARM64 package repository ($suite)" \
    release "$REPO_DIR/dists/$suite" > "$REPO_DIR/dists/$suite/Release"
done

signed=false
if [[ -n "${APT_REPO_GPG_PRIVATE_KEY:-}" ]]; then
  gnupg_home="$(mktemp -d)"
  chmod 700 "$gnupg_home"
  export GNUPGHOME="$gnupg_home"
  trap 'rm -rf "$gnupg_home"' EXIT

  printf '%s' "$APT_REPO_GPG_PRIVATE_KEY" | gpg --batch --import
  fingerprint="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
  [[ -n "$fingerprint" ]] || { echo "No secret GPG key found after import"; exit 1; }

  gpg --batch --yes --export "$fingerprint" > "$REPO_DIR/repo-key.gpg"

  sign_args=(--batch --yes --local-user "$fingerprint")
  if [[ -n "${APT_REPO_GPG_PASSPHRASE:-}" ]]; then
    sign_args+=(--pinentry-mode loopback --passphrase "$APT_REPO_GPG_PASSPHRASE")
  fi

  for suite in "${SUITES[@]}"; do
    gpg "${sign_args[@]}" --clearsign \
      --output "$REPO_DIR/dists/$suite/InRelease" \
      "$REPO_DIR/dists/$suite/Release"
    gpg "${sign_args[@]}" --armor --detach-sign \
      --output "$REPO_DIR/dists/$suite/Release.gpg" \
      "$REPO_DIR/dists/$suite/Release"
  done
  signed=true
else
  rm -f "$REPO_DIR/repo-key.gpg"
  for suite in "${SUITES[@]}"; do
    rm -f "$REPO_DIR/dists/$suite/InRelease" "$REPO_DIR/dists/$suite/Release.gpg"
  done
fi

package_count="$(find "$REPO_DIR/pool" -type f -name '*.deb' | wc -l | tr -d ' ')"
cat > "$REPO_DIR/index.html" <<EOF_HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Droidian Package Repository</title></head>
<body>
<h1>Droidian Package Repository</h1>
<p>Base: <code>deb [arch=arm64] ... main main</code></p>
<p>Additional: <code>deb [arch=arm64] ... additional main</code></p>
<p>Architecture: <code>arm64</code></p>
<p>Packages: <code>$package_count</code></p>
<p>Signed: <code>$signed</code></p>
</body>
</html>
EOF_HTML
: > "$REPO_DIR/.nojekyll"

echo "APT repository generated: suites=main,additional component=$COMPONENT packages=$package_count signed=$signed"
