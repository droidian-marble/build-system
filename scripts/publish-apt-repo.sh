#!/usr/bin/env bash
set -euo pipefail

INCOMING_DIR="${1:?usage: scripts/publish-apt-repo.sh <incoming-dir> <repository-dir>}"
REPO_DIR="${2:?usage: scripts/publish-apt-repo.sh <incoming-dir> <repository-dir>}"
SUITE="main"
COMPONENT="main"
MAX_VERSIONS=2

for cmd in apt-ftparchive dpkg dpkg-deb gzip gpg; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }
done

mkdir -p "$REPO_DIR/pool" "$REPO_DIR/dists/$SUITE/$COMPONENT/binary-arm64"
shopt -s nullglob

incoming_debs=()
while IFS= read -r -d '' deb; do
  arch="$(dpkg-deb -f "$deb" Architecture)"
  case "$arch" in
    arm64|all) incoming_debs+=("$deb") ;;
    *) echo "Skipping unsupported architecture: $(basename "$deb") [$arch]" ;;
  esac
done < <(find "$INCOMING_DIR" -type f -name '*.deb' -print0)

if ((${#incoming_debs[@]} == 0)); then
  echo "No ARM64/all .deb packages found in $INCOMING_DIR"
  exit 2
fi

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
  trap 'rm -rf "$gnupg_home"' EXIT

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
