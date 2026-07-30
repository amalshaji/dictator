#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 REF VERSION TAG" >&2
  exit 2
fi

ref=$1
version=$2
tag=$3
repo_root=$(cd "$(dirname "$0")/../.." && pwd)

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || $tag != "v$version" ]]; then
  echo "Stable release identity does not match: $version ($tag)" >&2
  exit 1
fi
if ! commit=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null); then
  echo "Git ref does not resolve to a commit: $ref" >&2
  exit 1
fi

git fetch origin main --tags
if ! git merge-base --is-ancestor "$commit" origin/main; then
  echo "Release commit is not reachable from origin/main: $commit" >&2
  exit 1
fi

latest_stable_tag() {
  local candidate
  while IFS= read -r candidate; do
    if [[ $candidate =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(git tag --list 'v*' --sort=-version:refname)
}

latest_tag=$(latest_stable_tag)
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  "$repo_root/scripts/release/release-tag.sh" verify "$tag" "$commit" >/dev/null
  if [[ $tag != "$latest_tag" ]]; then
    echo "Only the latest stable tag can be repaired: $tag != $latest_tag" >&2
    exit 1
  fi
  echo tagged
  exit 0
fi

if [[ -n $latest_tag ]]; then
  "$repo_root/scripts/release/version-greater-than.sh" \
    "${latest_tag#v}" "$version"
fi
if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release $tag exists without its required annotated tag" >&2
  exit 1
fi

echo new
