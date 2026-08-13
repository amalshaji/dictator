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
assert_absent "$stable" '^      ref:'
assert_contains "$stable" '^      strategy:'
assert_contains "$stable" '^          - patch$'
assert_contains "$stable" '^          - minor$'
assert_contains "$stable" '^          - major$'
assert_contains "$stable" '^          - explicit$'
assert_before "$stable" '          - patch' '          - minor'
assert_before "$stable" '          - minor' '          - major'
assert_before "$stable" '          - major' '          - explicit'
assert_contains "$stable" '^      explicit_version:'
assert_contains "$stable" '^  version:'
assert_contains "$stable" '^  prepare:'
assert_contains "$stable" '^  finalize:'
assert_contains "$stable" '^    environment: stable-release$'
assert_contains "$stable" '^  publish:$'
assert_contains "$stable" '^    needs: finalize$'
assert_contains "$stable" 'uses: ./\.github/workflows/release-published\.yml'
assert_count "$stable" 'scripts/release/validate-stable-candidate.sh' 1
assert_count "$stable" 'scripts/release/select-stable-version.sh' 1
assert_count "$stable" 'scripts/release/release-tag.sh ensure' 1
assert_count "$stable" 'scripts/release/publish-github-release.sh' 1
assert_before "$stable" 'scripts/release/select-stable-version.sh' 'scripts/release/build-release.sh'
assert_before "$stable" 'scripts/release/build-release.sh' 'scripts/release/release-tag.sh ensure'
assert_before "$stable" 'actions/attest-build-provenance@' 'scripts/release/release-tag.sh ensure'
assert_before "$stable" 'actions/upload-artifact@' 'scripts/release/release-tag.sh ensure'
version_job=$(job_block "$stable" version)
prepare_job=$(job_block "$stable" prepare)
finalize_job=$(job_block "$stable" finalize)
grep -q '^      contents: write$' <<<"$version_job"
grep -q '^      pull-requests: write$' <<<"$version_job"
grep -q 'select-stable-version\.sh' <<<"$version_job"
grep -q 'git commit' <<<"$version_job"
grep -q 'gh pr create' <<<"$version_job"
if grep -q 'git push origin HEAD:main\|release-tag\.sh ensure\|gh release' \
  <<<"$version_job"; then
  echo "Version preparation must not create tags or releases" >&2
  exit 1
fi
grep -q '^    needs: version$' <<<"$prepare_job"
grep -q '^    environment: release$' <<<"$prepare_job"
grep -q '^      contents: read$' <<<"$prepare_job"
if grep -q 'contents: write\|release-tag\.sh ensure\|gh release' <<<"$prepare_job"; then
  echo "Stable preparation must not have release mutation capabilities" >&2
  exit 1
fi
grep -q '^    needs: \[version, prepare\]$' <<<"$finalize_job"
grep -q '^    environment: stable-release$' <<<"$finalize_job"
grep -q '^      contents: write$' <<<"$finalize_job"
grep -q '^      pull-requests: write$' <<<"$finalize_job"
grep -q 'gh pr merge' <<<"$finalize_job"
# shellcheck disable=SC2016
grep -q -- '--match-head-commit "$CANDIDATE_SHA"' <<<"$finalize_job"
grep -q 'release-tag\.sh ensure' <<<"$finalize_job"
grep -q 'publish-github-release\.sh' <<<"$finalize_job"
assert_before "$stable" 'gh pr merge' 'scripts/release/release-tag.sh ensure'

assert_count "$canary" 'scripts/release/release-tag.sh verify' 1
assert_count "$canary" 'scripts/release/release-tag.sh ensure' 1
# shellcheck disable=SC2016
assert_before "$canary" 'scripts/release/verify-release-assets.sh "$assets"' \
  'scripts/release/release-tag.sh verify'
assert_before "$canary" 'scripts/release/build-release.sh' \
  'scripts/release/release-tag.sh ensure'
assert_before "$canary" 'actions/attest-build-provenance@' \
  'scripts/release/release-tag.sh ensure'

for workflow in "$stable" "$canary"; do
  assert_count "$workflow" 'scripts/release/with-signing-keychain.sh' 1
  assert_contains "$workflow" 'APPLE_CERTIFICATE:.*secrets\.APPLE_CERTIFICATE'
  assert_contains "$workflow" 'APPLE_CERTIFICATE_PASSWORD:.*secrets\.APPLE_CERTIFICATE_PASSWORD'
  assert_contains "$workflow" 'APPLE_SIGNING_IDENTITY:.*secrets\.APPLE_SIGNING_IDENTITY'
  assert_contains "$workflow" 'APPLE_ID:.*secrets\.APPLE_ID'
  assert_contains "$workflow" 'APPLE_APP_SPECIFIC_PASSWORD:.*secrets\.APPLE_APP_SPECIFIC_PASSWORD'
  assert_contains "$workflow" 'APPLE_TEAM_ID:.*secrets\.APPLE_TEAM_ID'
done

for workflow in .github/workflows/ci.yml "$stable" "$canary"; do
  assert_absent "$workflow" 'brew install xcodegen'
done
assert_contains .github/workflows/ci.yml 'scripts/xcodegen.sh --version'
assert_contains .github/workflows/ci.yml 'scripts/xcodegen.sh generate'
assert_contains .github/workflows/ci.yml 'Tests/ReleaseScripts/test-release-version.sh'
assert_contains scripts/release/build-release.sh 'scripts/xcodegen.sh generate'
assert_contains scripts/release/build-release.sh 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO'
assert_contains scripts/release/build-release.sh 'OTHER_CODE_SIGN_FLAGS=--timestamp'
assert_contains scripts/release/build-release.sh 'APPLE_SIGNING_IDENTITY'
assert_absent scripts/release/build-release.sh 'CODE_SIGN_IDENTITY=-'
assert_absent scripts/release/build-release.sh 'Signature=adhoc'
assert_contains scripts/release/verify-release-assets.sh 'stapler validate'
assert_contains scripts/release/verify-release-assets.sh 'spctl --assess'
assert_contains scripts/release/verify-release-assets.sh 'type execute'
# shellcheck disable=SC2016
assert_absent README.md 'Bump `MARKETING_VERSION`'
# shellcheck disable=SC2016
assert_contains README.md '`patch`, `minor`, `major`, or `explicit`'
# shellcheck disable=SC2016
assert_contains README.md 'creates a version-only release PR'
assert_absent README.md 'xattr -dr com\.apple\.quarantine'
assert_contains README.md 'Developer ID-signed and notarized'
# shellcheck disable=SC2016
assert_absent AGENTS.md '`xcodegen generate`'
# shellcheck disable=SC2016
assert_contains AGENTS.md '`scripts/xcodegen\.sh generate`'
