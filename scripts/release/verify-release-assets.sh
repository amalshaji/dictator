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
expected_team_id=${APPLE_TEAM_ID:-6NJKY8HB47}
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
xcrun stapler validate "$dmg" >&2
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=2 \
  "$dmg" >&2
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mountpoint" >&2
attached=true

app="$mountpoint/Dictator.app"
plist="$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app" >&2
spctl --assess --type execute --verbose=2 "$app" >&2
signature_details=$(codesign -dv --verbose=4 "$app" 2>&1)
grep -Eq '^Authority=Developer ID Application:' <<<"$signature_details"
grep -Fq "TeamIdentifier=$expected_team_id" <<<"$signature_details"
grep -Eq '^Timestamp=' <<<"$signature_details"
grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$signature_details"
entitlements=$(codesign -d --entitlements - "$app" 2>/dev/null)
if grep -q 'com.apple.security.get-task-allow' <<<"$entitlements"; then
  echo "Release app includes com.apple.security.get-task-allow" >&2
  exit 1
fi
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
