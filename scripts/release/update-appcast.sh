#!/bin/bash
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "usage: $0 SPARKLE_BIN FEED_DIR DMG VERSION BUILD_NUMBER EXPECTED_URL DOWNLOAD_URL_PREFIX LINK RELEASE_NOTES" >&2
  exit 2
fi

sparkle_bin=$1
feed_dir=$2
dmg=$3
version=$4
build_number=$5
expected_url=$6
download_url_prefix=$7
link=$8
release_notes=$9
appcast="$feed_dir/appcast.xml"
key_file=$(mktemp)
updates=$(mktemp -d)
trap 'rm -f "$key_file"; rm -rf "$updates"' EXIT

cat > "$key_file"
chmod 600 "$key_file"
if [[ ! -s $key_file ]]; then
  echo "Sparkle private key is empty" >&2
  exit 1
fi
if [[ ! $build_number =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer: $build_number" >&2
  exit 1
fi
mkdir -p "$feed_dir"

if [[ -f $appcast ]]; then
  matching_url_count=$(xmllint --xpath \
    "count(//*[local-name()='item']/*[local-name()='enclosure' and @url='$expected_url'])" \
    "$appcast")
  if [[ $matching_url_count != 0 ]]; then
    signature=$(scripts/release/validate-appcast.sh \
      "$appcast" "$dmg" "$version" "$build_number" "$expected_url")
    "$sparkle_bin/sign_update" --verify --ed-key-file "$key_file" "$appcast"
    "$sparkle_bin/sign_update" --verify --ed-key-file "$key_file" "$dmg" "$signature"
    echo "Existing appcast entry is valid"
    exit 0
  fi

  build_count=$(xmllint --xpath \
    "count(//*[local-name()='item']/*[local-name()='version'])" \
    "$appcast")
  latest_build=0
  for ((index = 1; index <= build_count; index++)); do
    existing_build=$(xmllint --xpath \
      "string((//*[local-name()='item']/*[local-name()='version'])[$index])" \
      "$appcast")
    if [[ ! $existing_build =~ ^[1-9][0-9]*$ ]]; then
      echo "Invalid existing appcast build: $existing_build" >&2
      exit 1
    fi
    if (( 10#$existing_build > 10#$latest_build )); then
      latest_build=$existing_build
    fi
  done
  if (( 10#$build_number <= 10#$latest_build )); then
    echo "Appcast build must increase: $latest_build -> $build_number" >&2
    exit 1
  fi
  cp "$appcast" "$updates/appcast.xml"
fi

dmg_name=$(basename "$dmg")
cp "$dmg" "$updates/$dmg_name"
cp "$release_notes" "$updates/${dmg_name%.*}.md"

"$sparkle_bin/generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "$download_url_prefix" \
  --link "$link" \
  --embed-release-notes \
  --maximum-deltas 0 \
  --maximum-versions 3 \
  -o "$updates/appcast.xml" \
  "$updates"

signature=$(scripts/release/validate-appcast.sh \
  "$updates/appcast.xml" "$dmg" "$version" "$build_number" "$expected_url")
"$sparkle_bin/sign_update" --verify --ed-key-file "$key_file" "$updates/appcast.xml"
"$sparkle_bin/sign_update" --verify --ed-key-file "$key_file" "$dmg" "$signature"
cp "$updates/appcast.xml" "$appcast"
