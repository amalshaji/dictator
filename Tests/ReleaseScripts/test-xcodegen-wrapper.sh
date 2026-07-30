#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cache=$(mktemp -d)
wrong_cache=$(mktemp -d)
log=$(mktemp)
trap 'rm -rf "$cache" "$wrong_cache" "$log"' EXIT

mkdir -p "$cache/bin" "$wrong_cache/bin"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'if [[ ${1:-} == --version ]]; then' \
  '  echo "Version: 2.46.0"' \
  'else' \
  '  printf "%s\n" "$*" >> "$XCODEGEN_TEST_LOG"' \
  'fi' > "$cache/bin/xcodegen"
chmod +x "$cache/bin/xcodegen"

XCODEGEN_CACHE_DIR="$cache" XCODEGEN_TEST_LOG="$log" \
  "$repo_root/scripts/xcodegen.sh" generate --spec project.yml
test "$(cat "$log")" = 'generate --spec project.yml'

printf '%s\n' '#!/bin/bash' 'echo "Version: 2.45.4"' \
  > "$wrong_cache/bin/xcodegen"
chmod +x "$wrong_cache/bin/xcodegen"
if XCODEGEN_CACHE_DIR="$wrong_cache" \
  "$repo_root/scripts/xcodegen.sh" --version >/dev/null 2>&1; then
  echo "Expected the XcodeGen wrapper to reject the wrong cached version" >&2
  exit 1
fi

grep -q '^xcodegen_version=2\.46\.0$' "$repo_root/scripts/xcodegen.sh"
grep -q '^archive_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806$' \
  "$repo_root/scripts/xcodegen.sh"
