#!/bin/bash
set -euo pipefail

xcodegen_version=2.46.0
archive_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
archive_url="https://github.com/yonaskolb/XcodeGen/releases/download/${xcodegen_version}/xcodegen.zip"
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cache_dir=${XCODEGEN_CACHE_DIR:-$repo_root/.build/tools/xcodegen-$xcodegen_version}
binary="$cache_dir/bin/xcodegen"

if [[ ! -x $binary ]]; then
  if [[ -e $cache_dir ]]; then
    echo "Incomplete XcodeGen cache: $cache_dir" >&2
    exit 1
  fi

  temporary_dir=$(mktemp -d)
  trap 'rm -rf "$temporary_dir"' EXIT
  archive="$temporary_dir/xcodegen.zip"
  curl --fail --location --silent --show-error \
    --retry 3 \
    --output "$archive" \
    "$archive_url"
  printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 -c -
  unzip -q "$archive" -d "$temporary_dir"
  test -x "$temporary_dir/xcodegen/bin/xcodegen"

  mkdir -p "$(dirname "$cache_dir")"
  if ! mv "$temporary_dir/xcodegen" "$cache_dir"; then
    test -x "$binary"
  fi
fi

actual_version=$("$binary" --version)
if [[ $actual_version != "Version: $xcodegen_version" ]]; then
  echo "Expected XcodeGen $xcodegen_version, found: $actual_version" >&2
  exit 1
fi

exec "$binary" "$@"
