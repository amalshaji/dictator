#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
workspace=$(mktemp -d)
fake_bin="$workspace/bin"
mkdir -p "$fake_bin"
trap 'rm -rf "$workspace"' EXIT

cat > "$fake_bin/xcodegen" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == generate ]]
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: \([0-9.]*\)$/\1/p' \
  "$RELEASE_VERSION_ROOT/project.yml")
VERSION="$version" perl -0pi -e \
  's/(MARKETING_VERSION = )[0-9.]+;/${1}$ENV{VERSION};/g' \
  "$RELEASE_VERSION_ROOT/Dictator.xcodeproj/project.pbxproj"
SCRIPT

cat > "$fake_bin/gh" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
[[ $1 == release && $2 == view ]]
if [[ ${3:-} != "${FAKE_RELEASE_TAG:-}" ]]; then
  exit 1
fi
case ${FAKE_RELEASE_STATE:-missing} in
  published)
    printf '%s\n' '{"isDraft":false,"isPrerelease":false}'
    ;;
  draft)
    printf '%s\n' '{"isDraft":true,"isPrerelease":false}'
    ;;
  missing)
    exit 1
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT
chmod +x "$fake_bin/xcodegen" "$fake_bin/gh"

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

write_version_files() {
  local directory=$1
  local version=$2
  mkdir -p "$directory/Dictator.xcodeproj"
  printf 'targets:\n  Dictator:\n    settings:\n      base:\n        MARKETING_VERSION: %s\n' \
    "$version" > "$directory/project.yml"
  printf 'MARKETING_VERSION = %s;\nMARKETING_VERSION = %s;\n' \
    "$version" "$version" > "$directory/Dictator.xcodeproj/project.pbxproj"
}

make_released_repo() {
  local version=$1
  local directory
  local remote
  directory=$(mktemp -d "$workspace/released.XXXXXX")
  remote=$(mktemp -d "$workspace/remote.XXXXXX")
  git -C "$directory" init -q -b main
  git -C "$directory" config user.name 'Release Tests'
  git -C "$directory" config user.email release-tests@example.com
  git -C "$directory" config commit.gpgsign false
  write_version_files "$directory" "$version"
  git -C "$directory" add project.yml Dictator.xcodeproj/project.pbxproj
  git -C "$directory" commit -qm "Release $version"
  git -C "$directory" tag -a "v$version" -m "v$version"
  git -C "$remote" init --bare -q
  git -C "$directory" remote add origin "$remote"
  git -C "$directory" push -q -u origin main "v$version"
  printf '%s\n' "$directory"
}

make_unfinished_repo() {
  local previous=$1
  local current=$2
  local directory
  directory=$(make_released_repo "$previous")
  write_version_files "$directory" "$current"
  git -C "$directory" add project.yml Dictator.xcodeproj/project.pbxproj
  git -C "$directory" commit -qm "Prepare $current release"
  git -C "$directory" push -q origin main
  printf '%s\n' "$directory"
}

make_advanced_released_repo() {
  local directory
  directory=$(make_released_repo 1.2.3)
  printf 'post-release change\n' > "$directory/change.txt"
  git -C "$directory" add change.txt
  git -C "$directory" commit -qm 'Add post-release change'
  git -C "$directory" push -q origin main
  printf '%s\n' "$directory"
}

select_version() {
  local directory=$1
  local release_state=$2
  local current_version
  shift 2
  current_version=$(sed -n 's/.*MARKETING_VERSION: //p' "$directory/project.yml")
  RELEASE_VERSION_ROOT="$directory" \
    XCODEGEN_BIN="$fake_bin/xcodegen" \
    GH_BIN="$fake_bin/gh" \
    FAKE_RELEASE_STATE="$release_state" \
    FAKE_RELEASE_TAG="v$current_version" \
    "$repo_root/scripts/release/select-stable-version.sh" "$@"
}

assert_bump() {
  local strategy=$1
  local explicit=$2
  local expected=$3
  local directory
  directory=$(make_released_repo 1.2.3)
  test "$(select_version "$directory" published "$strategy" "$explicit")" = \
    "$(printf 'bumped\t%s\tv%s' "$expected" "$expected")"
  test "$(sed -n 's/.*MARKETING_VERSION: //p' "$directory/project.yml")" = \
    "$expected"
  test "$(grep -c "MARKETING_VERSION = $expected;" \
    "$directory/Dictator.xcodeproj/project.pbxproj")" -eq 2
  test "$(git -C "$directory" diff --name-only | sort)" = \
    $'Dictator.xcodeproj/project.pbxproj\nproject.yml'
}

assert_bump patch '' 1.2.4
assert_bump minor '' 1.3.0
assert_bump major '' 2.0.0
assert_bump explicit 2.4.6 2.4.6

advanced_repo=$(make_advanced_released_repo)
test "$(select_version "$advanced_repo" published patch '')" = \
  $'bumped\t1.2.4\tv1.2.4'
test "$(sed -n 's/.*MARKETING_VERSION: //p' "$advanced_repo/project.yml")" = \
  1.2.4

invalid_repo=$(make_released_repo 1.2.3)
assert_fails select_version "$invalid_repo" published explicit ''
assert_fails select_version "$invalid_repo" published explicit 1.2.3
assert_fails select_version "$invalid_repo" published explicit 1.2.2
assert_fails select_version "$invalid_repo" published explicit 01.3.0
assert_fails select_version "$invalid_repo" published explicit 9999999999.0.0
assert_fails select_version "$invalid_repo" published patch 1.2.4
assert_fails select_version "$invalid_repo" published unsupported ''

maximum_repo=$(make_released_repo 999999999.999999999.999999999)
assert_fails select_version "$maximum_repo" published patch ''

malformed_repo=$(make_released_repo 1.2.3)
write_version_files "$malformed_repo" invalid
git -C "$malformed_repo" add project.yml Dictator.xcodeproj/project.pbxproj
git -C "$malformed_repo" commit -qm 'Add malformed version'
git -C "$malformed_repo" push -q origin main
assert_fails select_version "$malformed_repo" missing patch ''

unfinished_repo=$(make_unfinished_repo 1.2.3 1.2.4)
test "$(select_version "$unfinished_repo" missing patch '')" = \
  $'recovery\t1.2.4\tv1.2.4'
test -z "$(git -C "$unfinished_repo" status --porcelain)"
test "$(select_version "$unfinished_repo" missing explicit 1.2.4)" = \
  $'recovery\t1.2.4\tv1.2.4'
assert_fails select_version "$unfinished_repo" missing explicit 1.3.0

draft_repo=$(make_released_repo 1.2.3)
test "$(select_version "$draft_repo" draft patch '')" = \
  $'recovery\t1.2.3\tv1.2.3'
test -z "$(git -C "$draft_repo" status --porcelain)"

dirty_repo=$(make_released_repo 1.2.3)
printf dirty >> "$dirty_repo/project.yml"
assert_fails select_version "$dirty_repo" published patch ''
