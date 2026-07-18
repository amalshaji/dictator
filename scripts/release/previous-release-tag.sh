#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 CHANNEL REF" >&2
  exit 2
fi

channel=$1
ref=$2
case "$channel" in
  canary|stable) ;;
  *)
    echo "Channel must be canary or stable: $channel" >&2
    exit 1
    ;;
esac

if ! commit=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null); then
  echo "Git ref does not resolve to a commit: $ref" >&2
  exit 1
fi
if ! parent=$(git rev-parse --verify "$commit^" 2>/dev/null); then
  exit 0
fi

if [[ $channel == canary ]] &&
  tag=$(git describe --tags --abbrev=0 --match 'canary-*' "$parent" 2>/dev/null); then
  printf '%s\n' "$tag"
elif tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$parent" 2>/dev/null); then
  printf '%s\n' "$tag"
fi
