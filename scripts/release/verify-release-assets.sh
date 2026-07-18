#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 ASSET_DIR VERSION [BUILD_NUMBER]" >&2
  exit 2
fi

asset_dir=$1
version=$2
expected_build=${3:-}
dmg="$asset_dir/Dictator-${version}-universal.dmg"
checksums="$asset_dir/SHA256SUMS.txt"
mountpoint=$(mktemp -d)
attached=false
cleanup() {
  if [[ $attached == true ]]; then
    hdiutil detach "$mountpoint" >/dev/null 2>&1 || true
  fi
  rmdir "$mountpoint" >/dev/null 2>&1 || true
}
trap cleanup EXIT

test -f "$dmg"
test -f "$checksums"
(cd "$asset_dir" && shasum -a 256 -c SHA256SUMS.txt) >&2
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mountpoint" >&2
attached=true

plist="$mountpoint/Dictator.app/Contents/Info.plist"
actual_version=$(plutil -extract CFBundleShortVersionString raw "$plist")
actual_build=$(plutil -extract CFBundleVersion raw "$plist")
if [[ $actual_version != "$version" ]]; then
  echo "Release version mismatch: $actual_version != $version" >&2
  exit 1
fi
if [[ -n $expected_build && $actual_build != "$expected_build" ]]; then
  echo "Release build mismatch: $actual_build != $expected_build" >&2
  exit 1
fi

hdiutil detach "$mountpoint" >&2
attached=false
printf '%s\t%s\n' "$dmg" "$actual_build"
