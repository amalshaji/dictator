#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 VERSION BUILD_NUMBER OUTPUT_DIR [PROJECT_VERSION]" >&2
  exit 2
fi

version=$1
build_number=$2
output_dir=$3
project_version=${4:-$version}
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
derived_data=$(mktemp -d)
trap 'rm -rf "$derived_data"' EXIT

cd "$repo_root"
expected_version=$(scripts/release/version.sh)
if [[ $project_version != "$expected_version" ]]; then
  echo "Project version $project_version does not match MARKETING_VERSION $expected_version" >&2
  exit 1
fi
if [[ ! $build_number =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer: $build_number" >&2
  exit 1
fi
if [[ $version != "$project_version" && $version != "$project_version-canary.$build_number" ]]; then
  echo "Release version must be $project_version or $project_version-canary.$build_number: $version" >&2
  exit 1
fi

xcodegen generate
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
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
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
grep -q 'Signature=adhoc' <<<"$signature_details"
lipo -archs "$executable" | grep -q 'arm64'
lipo -archs "$executable" | grep -q 'x86_64'
otool -L "$executable" | grep -q 'Sparkle.framework'
[[ $(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") == "$version" ]]
[[ $(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist") == "$build_number" ]]

scripts/release/create-dmg.sh "$app" "$version" "$output_dir"
