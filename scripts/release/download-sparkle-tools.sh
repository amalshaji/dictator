#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT_DIR" >&2
  exit 2
fi

output_dir=$1
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT

curl -fsSL \
  -o "$archive" \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip

expected_sha256=cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0
actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ $actual_sha256 != "$expected_sha256" ]]; then
  echo "Sparkle tools checksum mismatch: $actual_sha256" >&2
  exit 1
fi

mkdir -p "$output_dir"
unzip -q -o "$archive" -d "$output_dir"
test -x "$output_dir/bin/generate_appcast"
test -x "$output_dir/bin/sign_update"
