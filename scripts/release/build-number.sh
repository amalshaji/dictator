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

commit_count=$(git rev-list --count --first-parent "$commit")
if [[ ! $commit_count =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid first-parent commit count: $commit_count" >&2
  exit 1
fi

build_number=$((commit_count * 2))
if [[ $channel == stable ]]; then
  build_number=$((build_number + 1))
fi

printf '%s\n' "$build_number"
