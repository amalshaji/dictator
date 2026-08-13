#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
workspace=$(mktemp -d)
fake_bin="$workspace/bin"
log="$workspace/commands.log"
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$fake_bin" "$workspace/runner" "$workspace/assets"

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

assert_before_log() {
  local first=$1
  local second=$2
  local first_line
  local second_line
  first_line=$(grep -nF "$first" "$log" | head -1 | cut -d: -f1)
  second_line=$(grep -nF "$second" "$log" | head -1 | cut -d: -f1)
  test "$first_line" -lt "$second_line"
}

assert_absent_log() {
  if grep -qF "$1" "$log"; then
    echo "Expected command log not to contain: $1" >&2
    exit 1
  fi
}

cat > "$fake_bin/security" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
printf 'security %s\n' "$*" >> "$FAKE_LOG"
case $1 in
  list-keychains)
    if [[ " $* " != *" -s "* ]]; then
      printf '    "%s"\n' "$FAKE_LOGIN_KEYCHAIN"
    fi
    ;;
  find-identity)
    printf '  1) ABC123 "Developer ID Application: Test (TEAMID1234)"\n'
    printf '     1 valid identities found\n'
    ;;
esac
SCRIPT

cat > "$fake_bin/codesign" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$FAKE_LOG"
SCRIPT

cat > "$fake_bin/xcrun" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$FAKE_LOG"
if [[ $1 == notarytool && $2 == submit ]]; then
  printf '{"id":"test-submission","status":"%s"}\n' "${FAKE_NOTARY_STATUS:-Accepted}"
fi
SCRIPT

for command in spctl hdiutil; do
  cat > "$fake_bin/$command" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
SCRIPT
  chmod +x "$fake_bin/$command"
done

cat > "$fake_bin/test-command" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
if [[ ${1:-success} == check-secrets ]]; then
  if [[ -n ${APPLE_CERTIFICATE:-} || -n ${APPLE_CERTIFICATE_PASSWORD:-} ]]; then
    exit 1
  fi
fi
printf 'command %s\n' "${1:-success}" >> "$FAKE_LOG"
[[ ${1:-success} != fail ]]
SCRIPT

chmod +x \
  "$fake_bin/security" \
  "$fake_bin/codesign" \
  "$fake_bin/xcrun" \
  "$fake_bin/test-command"

certificate=$(printf certificate | base64)
signing_environment=(
  "PATH=$fake_bin:$PATH"
  "FAKE_LOG=$log"
  "FAKE_LOGIN_KEYCHAIN=$workspace/login.keychain-db"
  "RUNNER_TEMP=$workspace/runner"
  "APPLE_CERTIFICATE=$certificate"
  "APPLE_CERTIFICATE_PASSWORD=archive-password"
  "APPLE_SIGNING_IDENTITY=Developer ID Application: Test (TEAMID1234)"
)

assert_fails env \
  "PATH=$fake_bin:$PATH" \
  "$repo_root/scripts/release/with-signing-keychain.sh" \
  "$fake_bin/test-command"

: > "$log"
env "${signing_environment[@]}" \
  "$repo_root/scripts/release/with-signing-keychain.sh" \
  "$fake_bin/test-command" check-secrets
assert_before_log 'security import' 'command check-secrets'
assert_before_log 'command check-secrets' 'security delete-keychain'
assert_absent_log ' -t cert '
grep -qF -- '-f pkcs12' "$log"
grep -qF 'security set-key-partition-list' "$log"
grep -qF 'security find-identity' "$log"

: > "$log"
assert_fails env "${signing_environment[@]}" \
  "$repo_root/scripts/release/with-signing-keychain.sh" \
  "$fake_bin/test-command" fail
grep -qF 'command fail' "$log"
grep -qF 'security delete-keychain' "$log"

dmg="$workspace/assets/Dictator-1.2.3-universal.dmg"
printf dmg > "$dmg"
notary_environment=(
  "PATH=$fake_bin:$PATH"
  "FAKE_LOG=$log"
  "APPLE_ID=developer@example.com"
  "APPLE_APP_SPECIFIC_PASSWORD=app-password"
  "APPLE_SIGNING_IDENTITY=Developer ID Application: Test (TEAMID1234)"
  "APPLE_TEAM_ID=TEAMID1234"
)

: > "$log"
env "${notary_environment[@]}" \
  "$repo_root/scripts/release/notarize-release.sh" \
  "$workspace/assets" 1.2.3
assert_before_log 'codesign --force --timestamp --sign' 'xcrun notarytool submit'
assert_before_log 'xcrun notarytool submit' 'xcrun stapler staple'
assert_before_log 'xcrun stapler staple' 'xcrun stapler validate'
grep -qF 'spctl --assess' "$log"
(cd "$workspace/assets" && shasum -a 256 -c SHA256SUMS.txt)

: > "$log"
assert_fails env "${notary_environment[@]}" FAKE_NOTARY_STATUS=Invalid \
  "$repo_root/scripts/release/notarize-release.sh" \
  "$workspace/assets" 1.2.3
assert_absent_log 'xcrun stapler staple'
