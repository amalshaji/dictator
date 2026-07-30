#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 verify|ensure TAG REF" >&2
  exit 2
fi

action=$1
tag=$2
ref=$3
remote=${RELEASE_REMOTE:-origin}

case "$action" in
  verify|ensure) ;;
  *)
    echo "Action must be verify or ensure: $action" >&2
    exit 2
    ;;
esac
if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
  ! $tag =~ ^canary-[0-9]+\.[0-9]+\.[0-9]+-b[1-9][0-9]*-[0-9a-f]{8}$ ]]; then
  echo "Unsupported release tag: $tag" >&2
  exit 1
fi
if ! commit=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null); then
  echo "Git ref does not resolve to a commit: $ref" >&2
  exit 1
fi

fetch_remote_tag() {
  if ! git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
    return 1
  fi
  git fetch --force "$remote" "refs/tags/$tag:refs/tags/$tag"
}

verify_local_tag() {
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

if fetch_remote_tag; then
  verify_local_tag
  echo "existing"
  exit 0
fi

if [[ $action == verify ]]; then
  echo "Release tag does not exist: $tag" >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$tag"; then
  verify_local_tag
else
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git tag -a "$tag" -m "Release $tag" "$commit"
fi

if ! git push "$remote" "refs/tags/$tag"; then
  fetch_remote_tag
  verify_local_tag
  echo "existing"
  exit 0
fi

fetch_remote_tag
verify_local_tag
echo "created"
