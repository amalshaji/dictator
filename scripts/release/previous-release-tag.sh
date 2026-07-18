#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 REF" >&2
  exit 2
fi

if ! commit=$(git rev-parse --verify "$1^{commit}" 2>/dev/null); then
  echo "Git ref does not resolve to a commit: $1" >&2
  exit 1
fi
if ! parent=$(git rev-parse --verify "$commit^" 2>/dev/null); then
  exit 0
fi

if tag=$(git describe --tags --abbrev=0 --match 'canary-*' "$parent" 2>/dev/null); then
  printf '%s\n' "$tag"
elif tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$parent" 2>/dev/null); then
  printf '%s\n' "$tag"
fi
