#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)

assert_fails_in() {
  local directory=$1
  shift
  if (cd "$directory" && "$@") >/dev/null 2>&1; then
    echo "Expected command to fail in $directory: $*" >&2
    exit 1
  fi
}

test_repo=$(mktemp -d)
tag_remote=$(mktemp -d)
fake_bin=$(mktemp -d)
trap 'rm -rf "$test_repo" "$tag_remote" "$fake_bin"' EXIT

git -C "$test_repo" init -q
git -C "$test_repo" config user.name "Release Tests"
git -C "$test_repo" config user.email release-tests@example.com
git -C "$test_repo" config commit.gpgsign false
printf first > "$test_repo/file"
git -C "$test_repo" add file
git -C "$test_repo" commit -qm first
first_commit=$(git -C "$test_repo" rev-parse HEAD)
git -C "$test_repo" tag -a v1.0.0 -m v1.0.0 "$first_commit"
printf second > "$test_repo/file"
git -C "$test_repo" commit -qam second
second_commit=$(git -C "$test_repo" rev-parse HEAD)

git -C "$tag_remote" init --bare -q
git -C "$test_repo" remote add origin "$tag_remote"
git -C "$test_repo" push -q origin HEAD:main v1.0.0

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'if [[ $1 == release && $2 == view ]]; then' \
  '  [[ ${FAKE_RELEASE_EXISTS:-false} == true ]]' \
  '  exit' \
  'fi' \
  'exit 2' > "$fake_bin/gh"
chmod +x "$fake_bin/gh"

test "$(cd "$test_repo" && PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$second_commit" 2.0.0 v2.0.0)" = new

git -C "$test_repo" tag -a v2.0.0 -m v2.0.0 "$second_commit"
git -C "$test_repo" push -q origin v2.0.0
test "$(cd "$test_repo" && PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$second_commit" 2.0.0 v2.0.0)" = tagged

assert_fails_in "$test_repo" env PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$first_commit" 2.0.0 v2.0.0

git -C "$test_repo" tag v2.0.1 "$second_commit"
git -C "$test_repo" push -q origin v2.0.1
assert_fails_in "$test_repo" env PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$second_commit" 2.0.1 v2.0.1

git -C "$test_repo" tag -a v2.0.2 -m v2.0.2 "$first_commit"
git -C "$test_repo" push -q origin v2.0.2
assert_fails_in "$test_repo" env PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$second_commit" 2.0.2 v2.0.2

assert_fails_in "$test_repo" env PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$second_commit" 1.9.0 v1.9.0

printf off-main > "$test_repo/file"
git -C "$test_repo" commit -qam off-main
off_main_commit=$(git -C "$test_repo" rev-parse HEAD)
git -C "$test_repo" reset -q --hard "$second_commit"
assert_fails_in "$test_repo" env PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$off_main_commit" 3.0.0 v3.0.0

assert_fails_in "$test_repo" env PATH="$fake_bin:$PATH" \
  FAKE_RELEASE_EXISTS=true \
  "$repo_root/scripts/release/validate-stable-candidate.sh" \
  "$second_commit" 3.0.0 v3.0.0
