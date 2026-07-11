# Dictator

Dictator is a native macOS menu-bar dictation app. Hold `Fn` to record, release to transcribe with a user-selected cloud provider, and insert the result into the field that was focused when recording began. If no editable field was focused, the text is stored in Dictator's private clipboard.

## Shortcuts

- Hold `Fn`: record dictation
- `Option-Command-V`: paste the latest private-clipboard item
- `Option-Shift-Command-V`: open the private clipboard

## Providers

Speech-to-text adapters: Groq, Cloudflare Workers AI, xAI, Deepgram, AssemblyAI, and Gladia.

Optional cleanup adapters are configured independently with BYOK credentials: Groq, Cloudflare Workers AI, Gemini, xAI, OpenRouter, and any OpenAI-compatible endpoint. Keys are stored in macOS Keychain. Transcript history, vocabulary, styles, snippets, and private-clipboard data stay in local Application Support storage; recorded audio is not retained.

## Install

Homebrew is the recommended installation method:

```sh
brew install --cask amalshaji/taps/dictator
```

Dictator checks for updates once a day with [Sparkle](https://sparkle-project.org). It shows the release notes and always asks before installing. Automatic checks can be disabled under **Settings → Updates**, and **Check for Updates…** is also available from the app and menu-bar menus.

### Manual installation

Download `Dictator-<version>-universal.dmg` and `SHA256SUMS.txt` from the matching [GitHub Release](https://github.com/amalshaji/dictator/releases), then verify the download:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Open the DMG and drag Dictator to Applications. Dictator is currently ad-hoc signed rather than Apple-notarized, so remove quarantine from this app bundle only before opening it:

```sh
/usr/bin/xattr -dr com.apple.quarantine "/Applications/Dictator.app"
```

Only run that command for the checksum-verified artifact downloaded from the official release. It does not disable Gatekeeper globally or make the app notarized.

## Build and test

```sh
xcodegen generate
xcodebuild -project Dictator.xcodeproj -scheme Dictator -configuration Debug -destination 'platform=macOS' build
xcodebuild -project Dictator.xcodeproj -scheme Dictator -configuration Debug -destination 'platform=macOS' test
```

Live integration tests read provider keys from `.env` and skip providers that are not configured. Every configured STT provider receives the same `Tests/Fixtures/reference.wav` input.

```dotenv
GROQ_API_KEY=
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ACCOUNT_ID=
XAI_API_KEY=
DEEPGRAM_API_KEY=
ASSEMBLYAI_API_KEY=
GLADIA_API_KEY=
GEMINI_API_KEY=
OPENROUTER_API_KEY=
```

The app needs Microphone and Accessibility/Input Monitoring permission for recording, global shortcuts, focus detection, and insertion.

## Release process

1. Bump `MARKETING_VERSION` in `project.yml`.
2. Open a PR, apply the `release` label, and merge it into `main` after CI passes.
3. The merge creates `v<version>` and builds a draft GitHub Release containing the universal DMG, checksum, and provenance attestation.
4. Review and publish the draft release.
5. Publication signs and deploys the Sparkle appcast to the `gh-pages` branch and bootstraps or updates `Casks/dictator.rb` in [`amalshaji/homebrew-taps`](https://github.com/amalshaji/homebrew-taps).

Configure a protected GitHub environment named `release` with:

- `SPARKLE_PRIVATE_KEY`: the private Ed25519 key whose public half is committed as `SUPublicEDKey`.
- `HOMEBREW_TAP_TOKEN`: a fine-grained token with Contents read/write access only to `amalshaji/homebrew-taps`.

Configure GitHub Pages to use **GitHub Actions** as its source. The publishing workflow keeps the signed feed on `gh-pages` for rollback and deploys that exact feed to `https://amalshaji.github.io/dictator/appcast.xml` with GitHub's Pages deployment action. Keep an encrypted offline backup of the Sparkle private key; without Developer ID signing, losing it prevents trusted key rotation for existing installations.
