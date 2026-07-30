#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
test_repo=$(mktemp -d)
fake_bin=$(mktemp -d)
state_dir=$(mktemp -d)
trap 'rm -rf "$test_repo" "$fake_bin" "$state_dir"' EXIT

git -C "$test_repo" init -q
git -C "$test_repo" config user.name "Release Tests"
git -C "$test_repo" config user.email release-tests@example.com
git -C "$test_repo" config commit.gpgsign false
printf first > "$test_repo/file"
git -C "$test_repo" add file
git -C "$test_repo" commit -qm first
git -C "$test_repo" tag -a v1.0.0 -m v1.0.0
printf second > "$test_repo/file"
git -C "$test_repo" commit -qam second
git -C "$test_repo" tag -a v2.0.0 -m v2.0.0

mkdir -p "$test_repo/release" "$state_dir/assets"
printf dmg > "$test_repo/release/Dictator-2.0.0-universal.dmg"
printf sums > "$test_repo/release/SHA256SUMS.txt"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "$FAKE_GH_LOG"' \
  'state=$(cat "$FAKE_GH_STATE_DIR/state")' \
  'case "$1 $2" in' \
  '  "release view")' \
  '    [[ $state != absent ]] || exit 1' \
  '    draft=false' \
  '    [[ $state == public ]] || draft=true' \
  '    printf "{\"assets\":[{\"name\":\"Dictator-%s-universal.dmg\"},{\"name\":\"SHA256SUMS.txt\"}],\"isDraft\":%s,\"isPrerelease\":false}\n" "$FAKE_VERSION" "$draft"' \
  '    ;;' \
  '  "release create")' \
  '    printf draft > "$FAKE_GH_STATE_DIR/state"' \
  '    ;;' \
  '  "release upload")' \
  '    cp "$4" "$5" "$FAKE_GH_STATE_DIR/assets/"' \
  '    ;;' \
  '  "release download")' \
  '    mkdir -p "$5"' \
  '    cp "$FAKE_GH_STATE_DIR/assets/"* "$5/"' \
  '    ;;' \
  '  "release edit")' \
  '    printf public > "$FAKE_GH_STATE_DIR/state"' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' > "$fake_bin/gh"
chmod +x "$fake_bin/gh"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'test -f "$1/Dictator-${2}-universal.dmg"' \
  'test -f "$1/SHA256SUMS.txt"' \
  'printf "verified %s %s\n" "$2" "$3" >> "$FAKE_GH_LOG"' > "$fake_bin/verify"
chmod +x "$fake_bin/verify"

run_publisher() {
  (cd "$test_repo" &&
    GH_BIN="$fake_bin/gh" \
    RELEASE_ASSET_VERIFIER="$fake_bin/verify" \
    FAKE_GH_LOG="$state_dir/log" \
    FAKE_GH_STATE_DIR="$state_dir" \
    FAKE_VERSION=2.0.0 \
    "$repo_root/scripts/release/publish-github-release.sh" \
      release 2.0.0 5 v2.0.0 HEAD)
}

assert_before_log() {
  local first=$1
  local second=$2
  local first_line
  local second_line
  first_line=$(grep -nF "$first" "$state_dir/log" | head -1 | cut -d: -f1)
  second_line=$(grep -nF "$second" "$state_dir/log" | head -1 | cut -d: -f1)
  test "$first_line" -lt "$second_line"
}

printf absent > "$state_dir/state"
: > "$state_dir/log"
run_publisher
test "$(cat "$state_dir/state")" = public
assert_before_log 'release create' 'release upload'
assert_before_log 'release upload' 'verified 2.0.0 5'
assert_before_log 'verified 2.0.0 5' 'release edit'

printf draft > "$state_dir/state"
: > "$state_dir/log"
run_publisher
test "$(cat "$state_dir/state")" = public
test "$(grep -cF 'release create' "$state_dir/log" || true)" -eq 0
assert_before_log 'release upload' 'release edit'

printf public > "$state_dir/state"
: > "$state_dir/log"
run_publisher
test "$(cat "$state_dir/state")" = public
test "$(grep -cF 'release upload' "$state_dir/log" || true)" -eq 0
test "$(grep -cF 'release edit' "$state_dir/log" || true)" -eq 0
grep -qF 'verified 2.0.0 5' "$state_dir/log"
