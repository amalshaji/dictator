#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 TAG REF" >&2
  exit 2
fi

tag=$1
ref=$2
remote=${RELEASE_REMOTE:-origin}

if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
  ! $tag =~ ^canary-[0-9]+\.[0-9]+\.[0-9]+-b[1-9][0-9]*-[0-9a-f]{8}$ ]]; then
  echo "Unsupported release tag: $tag" >&2
  exit 1
fi
if ! commit=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null); then
  echo "Git ref does not resolve to a commit: $ref" >&2
  exit 1
fi

verify_tag() {
  local tagged_commit
  if [[ $(git cat-file -t "refs/tags/$tag") != tag ]]; then
    echo "Release tag must be annotated: $tag" >&2
    exit 1
  fi
  tagged_commit=$(git rev-list -n 1 "$tag")
  if [[ $tagged_commit != "$commit" ]]; then
    echo "Tag $tag points to $tagged_commit instead of $commit" >&2
    exit 1
  fi
}

if git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
  git fetch --force "$remote" "refs/tags/$tag:refs/tags/$tag"
  verify_tag
  echo "existing"
  exit 0
fi

if git show-ref --verify --quiet "refs/tags/$tag"; then
  verify_tag
else
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git tag -a "$tag" -m "Release $tag" "$commit"
fi

if git push "$remote" "refs/tags/$tag"; then
  echo "created"
  exit 0
fi

git fetch --force "$remote" "refs/tags/$tag:refs/tags/$tag"
verify_tag
echo "existing"
