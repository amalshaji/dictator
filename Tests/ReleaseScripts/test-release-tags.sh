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
trap 'rm -rf "$test_repo" "$tag_remote"' EXIT

git -C "$test_repo" init -q
git -C "$test_repo" config user.name "Release Tests"
git -C "$test_repo" config user.email release-tests@example.com
git -C "$test_repo" config commit.gpgsign false
printf first > "$test_repo/file"
git -C "$test_repo" add file
git -C "$test_repo" commit -qm first
first_commit=$(git -C "$test_repo" rev-parse HEAD)
printf second > "$test_repo/file"
git -C "$test_repo" commit -qam second
second_commit=$(git -C "$test_repo" rev-parse HEAD)
second_short_sha=$(git -C "$test_repo" rev-parse --short=8 "$second_commit")

git -C "$tag_remote" init --bare -q
git -C "$test_repo" remote add origin "$tag_remote"
git -C "$test_repo" push -q origin HEAD:main

(cd "$test_repo" &&
  "$repo_root/scripts/release/release-tag.sh" ensure v2.0.0 "$second_commit")
(cd "$test_repo" &&
  "$repo_root/scripts/release/release-tag.sh" verify v2.0.0 "$second_commit")
test "$(git -C "$tag_remote" rev-list -n 1 v2.0.0)" = "$second_commit"
test "$(git -C "$tag_remote" cat-file -t refs/tags/v2.0.0)" = tag
(cd "$test_repo" &&
  "$repo_root/scripts/release/release-tag.sh" ensure v2.0.0 "$second_commit")

assert_fails_in "$test_repo" \
  "$repo_root/scripts/release/release-tag.sh" verify v2.0.1 "$second_commit"

git -C "$test_repo" tag v2.0.1 "$first_commit"
git -C "$test_repo" push -q origin v2.0.1
assert_fails_in "$test_repo" \
  "$repo_root/scripts/release/release-tag.sh" verify v2.0.1 "$first_commit"
assert_fails_in "$test_repo" \
  "$repo_root/scripts/release/release-tag.sh" ensure v2.0.1 "$second_commit"

git -C "$test_repo" tag -a v2.0.2 -m v2.0.2 "$first_commit"
git -C "$test_repo" push -q origin v2.0.2
assert_fails_in "$test_repo" \
  "$repo_root/scripts/release/release-tag.sh" verify v2.0.2 "$second_commit"

canary_tag="canary-2.0.0-b4-$second_short_sha"
(cd "$test_repo" &&
  "$repo_root/scripts/release/release-tag.sh" ensure "$canary_tag" "$second_commit")
(cd "$test_repo" &&
  "$repo_root/scripts/release/release-tag.sh" verify "$canary_tag" "$second_commit")

assert_fails_in "$test_repo" \
  "$repo_root/scripts/release/release-tag.sh" verify unsupported "$second_commit"
assert_fails_in "$test_repo" \
  "$repo_root/scripts/release/release-tag.sh" ensure unsupported "$second_commit"
