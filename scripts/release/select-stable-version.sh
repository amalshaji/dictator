#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 patch|minor|major|explicit EXPLICIT_VERSION" >&2
  exit 2
fi

strategy=$1
explicit_version=$2
script_root=$(cd "$(dirname "$0")/../.." && pwd)
repo_root=${RELEASE_VERSION_ROOT:-$script_root}
remote=${RELEASE_REMOTE:-origin}
gh_bin=${GH_BIN:-gh}
xcodegen_bin=${XCODEGEN_BIN:-$repo_root/scripts/xcodegen.sh}

is_semver() {
  [[ $1 =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}

version_greater_than() {
  "$script_root/scripts/release/version-greater-than.sh" "$1" "$2" >/dev/null
}

latest_stable_tag() {
  local candidate
  while IFS= read -r candidate; do
    if is_semver "${candidate#v}"; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(git tag --list 'v*' --sort=-version:refname)
}

case $strategy in
  patch|minor|major)
    if [[ -n $explicit_version ]]; then
      echo "Explicit version is only valid with the explicit strategy" >&2
      exit 1
    fi
    ;;
  explicit)
    if ! is_semver "$explicit_version"; then
      echo "Explicit version must be strict semantic versioning: $explicit_version" >&2
      exit 1
    fi
    ;;
  *)
    echo "Version strategy must be patch, minor, major, or explicit: $strategy" >&2
    exit 1
    ;;
esac

cd "$repo_root"
if [[ -n $(git status --porcelain) ]]; then
  echo "Release version selection requires a clean worktree" >&2
  exit 1
fi

version_line_count=$(grep -Ec \
  '^[[:space:]]*MARKETING_VERSION: [0-9]+\.[0-9]+\.[0-9]+$' project.yml || true)
if [[ $version_line_count -ne 1 ]]; then
  echo "Expected one MARKETING_VERSION in project.yml" >&2
  exit 1
fi
current_version=$(sed -n \
  's/^[[:space:]]*MARKETING_VERSION: \([0-9.]*\)$/\1/p' project.yml)
if ! is_semver "$current_version"; then
  echo "Current project version is invalid: $current_version" >&2
  exit 1
fi

git fetch "$remote" main --tags >/dev/null
head_commit=$(git rev-parse HEAD)
main_commit=$(git rev-parse "refs/remotes/$remote/main")
if [[ $head_commit != "$main_commit" ]]; then
  echo "Release version selection must start at current $remote/main" >&2
  exit 1
fi

current_tag="v$current_version"
latest_tag=$(latest_stable_tag)
release_json=
if git ls-remote --exit-code --tags "$remote" \
  "refs/tags/$current_tag" >/dev/null 2>&1; then
  git fetch --force "$remote" \
    "refs/tags/$current_tag:refs/tags/$current_tag" >/dev/null
  if [[ $(git cat-file -t "refs/tags/$current_tag") != tag ]]; then
    echo "Stable release tag must be annotated: $current_tag" >&2
    exit 1
  fi
  tagged_commit=$(git rev-list -n 1 "$current_tag")
  if release_json=$("$gh_bin" release view "$current_tag" \
    --json isDraft,isPrerelease 2>/dev/null) &&
    [[ $(jq -r .isDraft <<<"$release_json") == false ]] &&
    [[ $(jq -r .isPrerelease <<<"$release_json") == false ]]; then
    release_complete=true
  else
    release_complete=false
    if [[ $tagged_commit != "$head_commit" ]]; then
      echo "Unfinished release tag $current_tag does not point to HEAD" >&2
      exit 1
    fi
  fi
else
  if "$gh_bin" release view "$current_tag" \
    --json isDraft,isPrerelease >/dev/null 2>&1; then
    echo "Release $current_tag exists without its required annotated tag" >&2
    exit 1
  fi
  release_complete=false
  if [[ -n $latest_tag ]] &&
    ! version_greater_than "${latest_tag#v}" "$current_version"; then
    echo "Unfinished version must be newer than $latest_tag: $current_version" >&2
    exit 1
  fi
fi

if [[ $release_complete == false ]]; then
  if [[ $strategy == explicit && $explicit_version != "$current_version" ]]; then
    echo "Recover unfinished version $current_version before selecting $explicit_version" >&2
    exit 1
  fi
  printf 'recovery\t%s\t%s\n' "$current_version" "$current_tag"
  exit 0
fi

IFS=. read -r major minor patch <<<"$current_version"
case $strategy in
  patch) next_version="$major.$minor.$((patch + 1))" ;;
  minor) next_version="$major.$((minor + 1)).0" ;;
  major) next_version="$((major + 1)).0.0" ;;
  explicit) next_version=$explicit_version ;;
esac

if ! is_semver "$next_version"; then
  echo "Selected version exceeds the supported semantic-version range: $next_version" >&2
  exit 1
fi
if ! version_greater_than "$current_version" "$next_version"; then
  echo "Selected version must be newer than $current_version: $next_version" >&2
  exit 1
fi
if [[ -n $latest_tag ]] &&
  ! version_greater_than "${latest_tag#v}" "$next_version"; then
  echo "Selected version must be newer than $latest_tag: $next_version" >&2
  exit 1
fi
next_tag="v$next_version"
if git ls-remote --exit-code --tags "$remote" \
  "refs/tags/$next_tag" >/dev/null 2>&1; then
  echo "Selected release tag already exists: $next_tag" >&2
  exit 1
fi
if "$gh_bin" release view "$next_tag" >/dev/null 2>&1; then
  echo "Selected GitHub Release already exists: $next_tag" >&2
  exit 1
fi

OLD_VERSION="$current_version" NEW_VERSION="$next_version" perl -0pi -e \
  's/(^[[:space:]]*MARKETING_VERSION: )\Q$ENV{OLD_VERSION}\E$/${1}$ENV{NEW_VERSION}/m' \
  project.yml
# Keep stdout clean: callers capture this script's output, and XcodeGen
# writes progress lines to stdout.
"$xcodegen_bin" generate >&2

changed_files=$(
  {
    git diff --name-only
    git ls-files --others --exclude-standard
  } | sort -u
)
expected_files=$'Dictator.xcodeproj/project.pbxproj\nproject.yml'
if [[ $changed_files != "$expected_files" ]]; then
  echo "Version selection changed unexpected files:" >&2
  printf '%s\n' "$changed_files" >&2
  exit 1
fi
if [[ $(sed -n \
  's/^[[:space:]]*MARKETING_VERSION: \([0-9.]*\)$/\1/p' project.yml) != \
  "$next_version" ]]; then
  echo "Version source was not updated to $next_version" >&2
  exit 1
fi
generated_version_count=$(grep -c "MARKETING_VERSION = $next_version;" \
  Dictator.xcodeproj/project.pbxproj || true)
if [[ $generated_version_count -ne 2 ]]; then
  echo "Generated project does not contain $next_version twice" >&2
  exit 1
fi

printf 'bumped\t%s\t%s\n' "$next_version" "$next_tag"
