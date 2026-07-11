#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 VERSION BUILD_NUMBER OUTPUT_DIR" >&2
  exit 2
fi

version=$1
build_number=$2
output_dir=$3
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
derived_data=$(mktemp -d)
trap 'rm -rf "$derived_data"' EXIT

cd "$repo_root"
expected_version=$(scripts/release/version.sh)
if [[ $version != "$expected_version" ]]; then
  echo "Tag version $version does not match MARKETING_VERSION $expected_version" >&2
  exit 1
fi
if [[ ! $build_number =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer: $build_number" >&2
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
codesign -dv --verbose=4 "$app" 2>&1 | grep -q 'Signature=adhoc'
lipo -archs "$executable" | grep -q 'arm64'
lipo -archs "$executable" | grep -q 'x86_64'
otool -L "$executable" | grep -q 'Sparkle.framework'
[[ $(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") == "$version" ]]
[[ $(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist") == "$build_number" ]]

scripts/release/create-dmg.sh "$app" "$version" "$output_dir"
