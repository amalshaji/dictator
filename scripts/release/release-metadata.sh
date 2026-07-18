#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 TAG IS_PRERELEASE" >&2
  exit 2
fi

tag=$1
is_prerelease=$2

if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ && "$is_prerelease" == false ]]; then
  printf 'stable\t%s\t\n' "${BASH_REMATCH[1]}"
elif [[ "$tag" =~ ^canary-([0-9]+\.[0-9]+\.[0-9]+)-b([1-9][0-9]*)-([0-9a-f]{8})$ && "$is_prerelease" == true ]]; then
  printf 'canary\t%s-canary.%s\t%s\n' \
    "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}" \
    "${BASH_REMATCH[3]}"
else
  echo "Tag and prerelease status do not identify a supported release: $tag ($is_prerelease)" >&2
  exit 1
fi
