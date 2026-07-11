#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 BASE_VERSION CANDIDATE_VERSION" >&2
  exit 2
fi

base=$1
candidate=$2
semver='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! $base =~ $semver || ! $candidate =~ $semver ]]; then
  echo "Versions must use MAJOR.MINOR.PATCH: $base -> $candidate" >&2
  exit 1
fi

IFS=. read -r base_major base_minor base_patch <<<"$base"
IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"

base_parts=("$base_major" "$base_minor" "$base_patch")
candidate_parts=("$candidate_major" "$candidate_minor" "$candidate_patch")
for index in 0 1 2; do
  if (( 10#${candidate_parts[$index]} > 10#${base_parts[$index]} )); then
    exit 0
  fi
  if (( 10#${candidate_parts[$index]} < 10#${base_parts[$index]} )); then
    break
  fi
done

echo "Release version must increase: $base -> $candidate" >&2
exit 1
