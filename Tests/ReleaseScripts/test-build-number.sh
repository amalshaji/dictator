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
