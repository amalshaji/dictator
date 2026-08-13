#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 COMMAND [ARG ...]" >&2
  exit 2
fi

for variable in \
  APPLE_CERTIFICATE \
  APPLE_CERTIFICATE_PASSWORD \
  APPLE_SIGNING_IDENTITY; do
  if [[ -z ${!variable:-} ]]; then
    echo "$variable must be set" >&2
    exit 1
  fi
done

signing_workspace=$(mktemp -d "${RUNNER_TEMP:-/tmp}/dictator-signing.XXXXXX")
certificate_path="$signing_workspace/developer-id.p12"
keychain_path="$signing_workspace/build.keychain-db"
keychain_password=$(openssl rand -hex 32)
keychain_created=false
original_keychains=()

while IFS= read -r keychain; do
  keychain=${keychain//\"/}
  keychain=${keychain#"${keychain%%[![:space:]]*}"}
  [[ -z $keychain ]] || original_keychains+=("$keychain")
done < <(security list-keychains -d user)

cleanup() {
  if ((${#original_keychains[@]})); then
    security list-keychains -d user -s "${original_keychains[@]}" \
      >/dev/null 2>&1 || true
  fi
  if [[ $keychain_created == true ]]; then
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  fi
  rm -rf "$signing_workspace"
}
trap cleanup EXIT

printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$certificate_path"
test -s "$certificate_path"

security create-keychain -p "$keychain_password" "$keychain_path"
keychain_created=true
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$certificate_path" \
  -k "$keychain_path" \
  -P "$APPLE_CERTIFICATE_PASSWORD" \
  -f pkcs12 \
  -T /usr/bin/codesign
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$keychain_password" \
  "$keychain_path"
security list-keychains -d user -s "$keychain_path" "${original_keychains[@]}"

identities=$(security find-identity -v -p codesigning "$keychain_path")
if ! grep -Fq "\"$APPLE_SIGNING_IDENTITY\"" <<<"$identities"; then
  echo "Imported certificate does not contain $APPLE_SIGNING_IDENTITY" >&2
  exit 1
fi

unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD
"$@"
