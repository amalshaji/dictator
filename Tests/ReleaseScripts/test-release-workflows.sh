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
assert_before "$stable" 'Build release assets' 'Ensure release tag'
assert_before "$stable" 'Attest release assets' 'Ensure release tag'
assert_before "$stable" 'Stage verified release assets' 'Ensure release tag'

assert_before "$canary" 'Build canary assets' 'Ensure canary tag'
assert_before "$canary" 'Attest canary assets' 'Ensure canary tag'
