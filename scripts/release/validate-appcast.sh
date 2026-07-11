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
if [[ $count != 1 ]]; then
  echo "Expected exactly one appcast item for version $version; found $count" >&2
  exit 1
fi

actual_build=$(xmllint --xpath "string($item/*[local-name()='version'])" "$appcast")
minimum_macos=$(xmllint --xpath "string($item/*[local-name()='minimumSystemVersion'])" "$appcast")
actual_url=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@url)" "$appcast")
actual_length=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@length)" "$appcast")
signature=$(xmllint --xpath "string($item/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast")

if [[ $actual_build != "$build_number" ]]; then
  echo "Appcast build mismatch: $actual_build != $build_number" >&2
  exit 1
fi
if [[ $minimum_macos != 14 && $minimum_macos != 14.0 && $minimum_macos != 14.0.0 ]]; then
  echo "Appcast minimum macOS must be 14: $minimum_macos" >&2
  exit 1
fi
if [[ $actual_url != "$expected_url" ]]; then
  echo "Appcast URL mismatch: $actual_url != $expected_url" >&2
  exit 1
fi
expected_length=$(stat -f %z "$dmg")
if [[ $actual_length != "$expected_length" ]]; then
  echo "Appcast length mismatch: $actual_length != $expected_length" >&2
  exit 1
fi
if [[ -z $signature ]]; then
  echo "Appcast item is missing an EdDSA signature" >&2
  exit 1
fi

printf '%s\n' "$signature"
