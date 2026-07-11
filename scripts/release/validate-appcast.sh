#!/bin/bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 APPCAST DMG VERSION BUILD_NUMBER EXPECTED_URL" >&2
  exit 2
fi

appcast=$1
dmg=$2
version=$3
build_number=$4
expected_url=$5
item="//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$version']]"

count=$(xmllint --xpath "count($item)" "$appcast")
[[ $count == 1 ]]

actual_build=$(xmllint --xpath "string($item/*[local-name()='version'])" "$appcast")
minimum_macos=$(xmllint --xpath "string($item/*[local-name()='minimumSystemVersion'])" "$appcast")
actual_url=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@url)" "$appcast")
actual_length=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@length)" "$appcast")
signature=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast")

[[ $actual_build == "$build_number" ]]
[[ $minimum_macos == 14 || $minimum_macos == 14.0 || $minimum_macos == 14.0.0 ]]
[[ $actual_url == "$expected_url" ]]
[[ $actual_length == "$(stat -f %z "$dmg")" ]]
[[ -n $signature ]]

printf '%s\n' "$signature"
