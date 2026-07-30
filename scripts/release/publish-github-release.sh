#!/bin/bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 ASSET_DIR VERSION BUILD_NUMBER TAG REF" >&2
  exit 2
fi

asset_dir=$1
version=$2
build_number=$3
tag=$4
ref=$5
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
gh_bin=${GH_BIN:-gh}
asset_verifier=${RELEASE_ASSET_VERIFIER:-$repo_root/scripts/release/verify-release-assets.sh}
verification_root=$(mktemp -d)
trap 'rm -rf "$verification_root"' EXIT

expected_assets=$(printf '%s\n%s\n' \
  "Dictator-${version}-universal.dmg" SHA256SUMS.txt | sort)

verify_release_shape() {
  local release_json=$1
  local expected_draft=$2
  local actual_assets
  [[ $(jq -r .isDraft <<<"$release_json") == "$expected_draft" ]]
  [[ $(jq -r .isPrerelease <<<"$release_json") == false ]]
  actual_assets=$(jq -r '.assets[].name' <<<"$release_json" | sort)
  if [[ $actual_assets != "$expected_assets" ]]; then
    echo "Release assets do not match the prepared assets" >&2
    exit 1
  fi
}

download_and_verify() {
  local destination=$1
  mkdir -p "$destination"
  "$gh_bin" release download "$tag" --dir "$destination"
  "$asset_verifier" "$destination" "$version" "$build_number"
}

if release_json=$("$gh_bin" release view "$tag" \
  --json assets,isDraft,isPrerelease 2>/dev/null); then
  [[ $(jq -r .isPrerelease <<<"$release_json") == false ]]
  if [[ $(jq -r .isDraft <<<"$release_json") == false ]]; then
    verify_release_shape "$release_json" false
    download_and_verify "$verification_root/existing"
    echo existing
    exit 0
  fi
else
  previous_tag=$(
    "$repo_root/scripts/release/previous-release-tag.sh" stable "$ref"
  )
  notes_arguments=(--generate-notes)
  if [[ -n $previous_tag ]]; then
    notes_arguments+=(--notes-start-tag "$previous_tag")
  fi
  "$gh_bin" release create "$tag" \
    --verify-tag \
    --draft \
    --title "$tag" \
    "${notes_arguments[@]}"
fi

"$gh_bin" release upload "$tag" \
  "$asset_dir/Dictator-${version}-universal.dmg" \
  "$asset_dir/SHA256SUMS.txt" \
  --clobber

release_json=$("$gh_bin" release view "$tag" \
  --json assets,isDraft,isPrerelease)
verify_release_shape "$release_json" true
download_and_verify "$verification_root/uploaded"
"$gh_bin" release edit "$tag" --draft=false --latest
echo published
