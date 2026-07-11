#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 APP_PATH VERSION OUTPUT_DIR" >&2
  exit 2
fi

app_path=$1
version=$2
output_dir=$3
dmg_name="Dictator-${version}-universal.dmg"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

mkdir -p "$output_dir"
ditto "$app_path" "$staging/Dictator.app"
ln -s /Applications "$staging/Applications"

hdiutil create \
  -volname "Dictator" \
  -srcfolder "$staging" \
  -format UDZO \
  -ov \
  "$output_dir/$dmg_name"

hdiutil verify "$output_dir/$dmg_name"
(
  cd "$output_dir"
  shasum -a 256 "$dmg_name" > SHA256SUMS.txt
)
