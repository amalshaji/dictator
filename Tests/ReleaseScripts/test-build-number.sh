#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

commit_count=$(git rev-list --count --first-parent HEAD)
canary_build=$(scripts/release/build-number.sh canary HEAD)
stable_build=$(scripts/release/build-number.sh stable HEAD)

test "$canary_build" = "$((commit_count * 2))"
test "$stable_build" = "$((commit_count * 2 + 1))"
test "$stable_build" -gt "$canary_build"
test "$((canary_build + 2))" -gt "$stable_build"

assert_fails scripts/release/build-number.sh preview HEAD
assert_fails scripts/release/build-number.sh canary does-not-exist

IFS=$'\t' read -r channel base_version version build_number short_sha tag < <(
  scripts/release/release-metadata.sh from-tag canary-1.2.3-b46-a1b2c3d4 true
)
test "$channel" = canary
test "$base_version" = 1.2.3
test "$version" = 1.2.3-canary.46
test "$build_number" = 46
test "$short_sha" = a1b2c3d4
test "$tag" = canary-1.2.3-b46-a1b2c3d4

IFS=$'\t' read -r channel base_version version build_number short_sha tag < <(
  scripts/release/release-metadata.sh from-tag v1.2.3 false
)
test "$channel" = stable
test "$base_version" = 1.2.3
test "$version" = 1.2.3
test "$build_number" = 0
test "$short_sha" = -
test "$tag" = v1.2.3

IFS=$'\t' read -r channel base_version version build_number short_sha tag < <(
  scripts/release/release-metadata.sh from-ref canary HEAD
)
test "$channel" = canary
test "$base_version" = "$(scripts/release/version.sh)"
test "$version" = "$base_version-canary.$canary_build"
test "$build_number" = "$canary_build"
test "$short_sha" = "$(git rev-parse --short=8 HEAD)"
test "$tag" = "canary-$base_version-b$canary_build-$short_sha"

IFS=$'\t' read -r channel base_version version build_number short_sha tag < <(
  scripts/release/release-metadata.sh from-ref stable HEAD
)
test "$channel" = stable
test "$base_version" = "$(scripts/release/version.sh)"
test "$version" = "$base_version"
test "$build_number" = "$stable_build"
test "$short_sha" = "$(git rev-parse --short=8 HEAD)"
test "$tag" = "v$base_version"

assert_fails scripts/release/release-metadata.sh from-tag v1.2.3 true
assert_fails scripts/release/release-metadata.sh from-tag canary-1.2.3-b46-a1b2c3d4 false
assert_fails scripts/release/release-metadata.sh from-tag canary-1.2.3-b0-a1b2c3d4 true
assert_fails scripts/release/release-metadata.sh from-tag preview-1.2.3 false
assert_fails scripts/release/release-metadata.sh from-ref preview HEAD

test_repo=$(mktemp -d)
trap 'rm -rf "$test_repo"' EXIT
git -C "$test_repo" init -q
git -C "$test_repo" config user.name "Release Tests"
git -C "$test_repo" config user.email release-tests@example.com
git -C "$test_repo" config commit.gpgsign false
printf first > "$test_repo/file"
git -C "$test_repo" add file
git -C "$test_repo" commit -qm first
first_commit=$(git -C "$test_repo" rev-parse HEAD)
git -C "$test_repo" tag v1.0.0
printf second > "$test_repo/file"
git -C "$test_repo" commit -qam second
second_commit=$(git -C "$test_repo" rev-parse HEAD)
second_short_sha=$(git -C "$test_repo" rev-parse --short=8 "$second_commit")
canary_tag="canary-1.0.0-b4-$second_short_sha"
git -C "$test_repo" tag "$canary_tag"
printf third > "$test_repo/file"
git -C "$test_repo" commit -qam third

test "$(cd "$test_repo" &&
  "$repo_root/scripts/release/previous-release-tag.sh" canary HEAD)" = "$canary_tag"
test "$(cd "$test_repo" &&
  "$repo_root/scripts/release/previous-release-tag.sh" canary "$second_commit")" = v1.0.0
test "$(cd "$test_repo" &&
  "$repo_root/scripts/release/previous-release-tag.sh" stable HEAD)" = v1.0.0
test -z "$(cd "$test_repo" &&
  "$repo_root/scripts/release/previous-release-tag.sh" stable "$first_commit")"

expired=$(printf '%s\n' \
  canary-1.0.0-b8-11111111 \
  canary-1.0.0-b12-22222222 \
  canary-1.0.0-b10-33333333 |
  scripts/release/select-expired-canaries.sh 2)
test "$expired" = canary-1.0.0-b8-11111111
assert_fails scripts/release/select-expired-canaries.sh 0
