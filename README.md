# Dictator

Dictator is a native macOS menu-bar dictation app. Hold `Fn` to record, release to transcribe with a user-selected cloud provider, and insert the result into the field that was focused when recording began. If no editable field was focused, the text is stored in Dictator's private clipboard.

## Shortcuts

- Hold `Fn`: record dictation
- `Option-Command-V`: paste the latest private-clipboard item
- `Option-Shift-Command-V`: open the private clipboard

## Providers

Speech-to-text adapters: Groq, Cloudflare Workers AI, xAI, Deepgram, AssemblyAI, and Gladia.

Optional cleanup adapters are configured independently with BYOK credentials: Groq, Cloudflare Workers AI, Gemini, xAI, OpenRouter, and any OpenAI-compatible endpoint. Keys are stored in macOS Keychain. Transcript history, vocabulary, styles, snippets, and private-clipboard data stay in local Application Support storage; recorded audio is not retained.

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
