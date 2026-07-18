#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)

if [[ ${1:-} == from-ref && $# -eq 3 ]]; then
  channel=$2
  ref=$3
  case "$channel" in
    canary|stable) ;;
    *)
      echo "Channel must be canary or stable: $channel" >&2
      exit 1
      ;;
  esac

  if ! commit=$(git -C "$repo_root" rev-parse --verify "$ref^{commit}" 2>/dev/null); then
    echo "Git ref does not resolve to a commit: $ref" >&2
    exit 1
  fi

  base_version=$("$repo_root/scripts/release/version.sh")
  build_number=$(cd "$repo_root" &&
    scripts/release/build-number.sh "$channel" "$commit")
  short_sha=$(git -C "$repo_root" rev-parse --short=8 "$commit")
  if [[ $channel == canary ]]; then
    version="$base_version-canary.$build_number"
    tag="canary-$base_version-b$build_number-$short_sha"
  else
    version=$base_version
    tag="v$base_version"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$channel" "$base_version" "$version" "$build_number" "$short_sha" "$tag"
elif [[ ${1:-} == from-tag && $# -eq 3 ]]; then
  tag=$2
  is_prerelease=$3
  if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ && "$is_prerelease" == false ]]; then
    base_version=${BASH_REMATCH[1]}
    printf 'stable\t%s\t%s\t0\t-\t%s\n' \
      "$base_version" "$base_version" "$tag"
  elif [[ "$tag" =~ ^canary-([0-9]+\.[0-9]+\.[0-9]+)-b([1-9][0-9]*)-([0-9a-f]{8})$ && "$is_prerelease" == true ]]; then
    base_version=${BASH_REMATCH[1]}
    build_number=${BASH_REMATCH[2]}
    short_sha=${BASH_REMATCH[3]}
    printf 'canary\t%s\t%s-canary.%s\t%s\t%s\t%s\n' \
      "$base_version" "$base_version" "$build_number" "$build_number" "$short_sha" "$tag"
  else
    echo "Tag and prerelease status do not identify a supported release: $tag ($is_prerelease)" >&2
    exit 1
  fi
else
  echo "usage: $0 from-ref CHANNEL REF | from-tag TAG IS_PRERELEASE" >&2
  exit 2
fi
