#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

stable=.github/workflows/publish.yml
canary=.github/workflows/canary.yml

assert_contains() {
  local file=$1
  local pattern=$2
  if ! grep -Eq "$pattern" "$file"; then
    echo "Expected $file to contain: $pattern" >&2
    exit 1
  fi
}

assert_absent() {
  local file=$1
  local pattern=$2
  if grep -Eq "$pattern" "$file"; then
    echo "Expected $file not to contain: $pattern" >&2
    exit 1
  fi
}

assert_count() {
  local file=$1
  local pattern=$2
  local expected=$3
  local actual
  actual=$(grep -cF "$pattern" "$file" || true)
  if [[ $actual -ne $expected ]]; then
    echo "Expected $file to contain '$pattern' $expected time(s), found $actual" >&2
    exit 1
  fi
}

assert_before() {
  local file=$1
  local first=$2
  local second=$3
  local first_line
  local second_line
  first_line=$(grep -nF "$first" "$file" | head -1 | cut -d: -f1 || true)
  second_line=$(grep -nF "$second" "$file" | head -1 | cut -d: -f1 || true)
  if [[ -z $first_line || -z $second_line || $first_line -ge $second_line ]]; then
    echo "Expected '$first' before '$second' in $file" >&2
    exit 1
  fi
}

job_block() {
  local file=$1
  local job=$2
  awk -v heading="  $job:" '
    $0 == heading { inside = 1; next }
    inside && /^  [a-zA-Z0-9_-]+:$/ { exit }
    inside { print }
  ' "$file"
}

if [[ -e .github/workflows/tag-on-merge.yml ]]; then
  echo "Stable release tags must not be created when release PRs merge" >&2
  exit 1
fi

assert_contains "$stable" '^  workflow_dispatch:'
assert_absent "$stable" '^  push:'
assert_contains "$stable" '^      ref:'
assert_contains "$stable" '^  prepare:'
assert_contains "$stable" '^  finalize:'
assert_contains "$stable" '^    needs: prepare$'
assert_contains "$stable" '^    environment: stable-release$'
assert_contains "$stable" '^  publish:$'
assert_contains "$stable" '^    needs: finalize$'
assert_contains "$stable" 'uses: ./\.github/workflows/release-published\.yml'
assert_count "$stable" 'scripts/release/validate-stable-candidate.sh' 2
assert_count "$stable" 'scripts/release/release-tag.sh ensure' 1
assert_count "$stable" 'scripts/release/publish-github-release.sh' 1
assert_before "$stable" 'scripts/release/build-release.sh' 'scripts/release/release-tag.sh ensure'
assert_before "$stable" 'actions/attest-build-provenance@' 'scripts/release/release-tag.sh ensure'
assert_before "$stable" 'actions/upload-artifact@' 'scripts/release/release-tag.sh ensure'
prepare_job=$(job_block "$stable" prepare)
finalize_job=$(job_block "$stable" finalize)
grep -q '^      contents: read$' <<<"$prepare_job"
if grep -q 'contents: write\|release-tag\.sh ensure\|gh release' <<<"$prepare_job"; then
  echo "Stable preparation must not have release mutation capabilities" >&2
  exit 1
fi
grep -q '^    needs: prepare$' <<<"$finalize_job"
grep -q '^    environment: stable-release$' <<<"$finalize_job"
grep -q '^      contents: write$' <<<"$finalize_job"
grep -q 'release-tag\.sh ensure' <<<"$finalize_job"
grep -q 'publish-github-release\.sh' <<<"$finalize_job"

assert_count "$canary" 'scripts/release/release-tag.sh verify' 1
assert_count "$canary" 'scripts/release/release-tag.sh ensure' 1
# shellcheck disable=SC2016
assert_before "$canary" 'scripts/release/verify-release-assets.sh "$assets"' \
  'scripts/release/release-tag.sh verify'
assert_before "$canary" 'scripts/release/build-release.sh' \
  'scripts/release/release-tag.sh ensure'
assert_before "$canary" 'actions/attest-build-provenance@' \
  'scripts/release/release-tag.sh ensure'

for workflow in .github/workflows/ci.yml "$stable" "$canary"; do
  assert_absent "$workflow" 'brew install xcodegen'
done
assert_contains .github/workflows/ci.yml 'scripts/xcodegen.sh --version'
assert_contains .github/workflows/ci.yml 'scripts/xcodegen.sh generate'
assert_contains scripts/release/build-release.sh 'scripts/xcodegen.sh generate'
# shellcheck disable=SC2016
assert_absent AGENTS.md '`xcodegen generate`'
# shellcheck disable=SC2016
assert_contains AGENTS.md '`scripts/xcodegen\.sh generate`'
