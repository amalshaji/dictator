#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 VERSION BUILD_NUMBER OUTPUT_DIR" >&2
  exit 2
fi

for variable in \
  APPLE_ID \
  APPLE_APP_SPECIFIC_PASSWORD \
  APPLE_SIGNING_IDENTITY \
  APPLE_TEAM_ID; do
  if [[ -z ${!variable:-} ]]; then
    echo "$variable must be set" >&2
    exit 1
  fi
done

version=$1
build_number=$2
output_dir=$3
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
derived_data=$(mktemp -d)
trap 'rm -rf "$derived_data"' EXIT

cd "$repo_root"
project_version=$(scripts/release/version.sh)
if [[ ! $build_number =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer: $build_number" >&2
  exit 1
fi
if [[ $version != "$project_version" && $version != "$project_version-canary.$build_number" ]]; then
  echo "Release version must be $project_version or $project_version-canary.$build_number: $version" >&2
  exit 1
fi

scripts/xcodegen.sh generate
xcodebuild -resolvePackageDependencies -project Dictator.xcodeproj -scheme Dictator
xcodebuild \
  -project Dictator.xcodeproj \
  -scheme Dictator \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$APPLE_SIGNING_IDENTITY" \
  "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  build

app="$derived_data/Build/Products/Release/Dictator.app"
executable="$app/Contents/MacOS/Dictator"
sparkle="$app/Contents/Frameworks/Sparkle.framework"

test -d "$app"
test -d "$sparkle"
test -L "$sparkle/Versions/Current"
codesign --verify --deep --strict --verbose=2 "$app"
signature_details=$(codesign -dv --verbose=4 "$app" 2>&1)
grep -Fq "Authority=$APPLE_SIGNING_IDENTITY" <<<"$signature_details"
grep -Fq "TeamIdentifier=$APPLE_TEAM_ID" <<<"$signature_details"
grep -Eq '^Timestamp=' <<<"$signature_details"
grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$signature_details"
entitlements=$(codesign -d --entitlements - "$app" 2>/dev/null)
if grep -q 'com.apple.security.get-task-allow' <<<"$entitlements"; then
  echo "Release app must not include com.apple.security.get-task-allow" >&2
  exit 1
fi
lipo -archs "$executable" | grep -q 'arm64'
lipo -archs "$executable" | grep -q 'x86_64'
otool -L "$executable" | grep -q 'Sparkle.framework'
[[ $(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") == "$version" ]]
[[ $(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist") == "$build_number" ]]

scripts/release/create-dmg.sh "$app" "$version" "$output_dir"
scripts/release/notarize-release.sh "$output_dir" "$version"
