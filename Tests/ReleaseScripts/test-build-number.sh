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

IFS=$'\t' read -r channel version short_sha < <(
  scripts/release/release-metadata.sh canary-1.2.3-b46-a1b2c3d4 true
)
test "$channel" = canary
test "$version" = 1.2.3-canary.46
test "$short_sha" = a1b2c3d4

IFS=$'\t' read -r channel version short_sha < <(
  scripts/release/release-metadata.sh v1.2.3 false
)
test "$channel" = stable
test "$version" = 1.2.3
test -z "$short_sha"

assert_fails scripts/release/release-metadata.sh v1.2.3 true
assert_fails scripts/release/release-metadata.sh canary-1.2.3-b46-a1b2c3d4 false
assert_fails scripts/release/release-metadata.sh canary-1.2.3-b0-a1b2c3d4 true
assert_fails scripts/release/release-metadata.sh preview-1.2.3 false
