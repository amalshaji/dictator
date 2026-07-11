# Repository Guidelines

## Project Structure & Module Organization

Dictator is a Swift 6 macOS 14+ app generated with XcodeGen. Application and SwiftUI code lives in `Sources/DictatorApp`; reusable models, storage, networking, provider adapters, and cleanup logic live in `Sources/DictatorCore`. Keep speech-to-text adapters under `Sources/DictatorCore/Providers` and cleanup adapters under `Sources/DictatorCore/LLM`. Tests mirror these boundaries in `Tests/DictatorAppTests`, `Tests/DictatorCoreTests`, and `Tests/DictatorIntegrationTests`. Shared live-test audio belongs in `Tests/Fixtures`, while app icons and other catalog assets belong in `Sources/DictatorApp/Assets.xcassets`.

## Build, Test, and Development Commands

- `xcodegen generate` regenerates `Dictator.xcodeproj` after editing `project.yml`.
- `xcodebuild -project Dictator.xcodeproj -scheme Dictator -configuration Debug -destination 'platform=macOS' build` compiles the app and core framework.
- `xcodebuild -project Dictator.xcodeproj -scheme Dictator -configuration Debug -destination 'platform=macOS' test` runs all unit and integration test targets.
- `open Dictator.xcodeproj` opens the generated project for local development and signing.

Run XcodeGen whenever targets, resources, entitlements, or build settings change. Do not hand-edit generated project settings when `project.yml` can express the change.

## Coding Style & Naming Conventions

Follow existing Swift conventions: four-space indentation, one primary type per file, `PascalCase` for types, and `camelCase` for methods and properties. Match filenames to their principal type, such as `CleanupCoordinator.swift`. Prefer value types and explicit `Sendable` conformance in `DictatorCore`; isolate UI-bound state with `@MainActor`. Keep provider-specific behavior behind the existing protocols and registries. No formatter or linter is configured, so use Xcode’s formatting and keep diffs focused.

## Testing Guidelines

Tests use XCTest. Name cases with a descriptive `test…` prefix and place them in the matching target. Add deterministic unit tests for core behavior and contract tests for provider adapters. Live tests load keys from `.env`, reuse `Tests/Fixtures/reference.wav`, and must skip cleanly when credentials are absent. Never commit API keys.

## Commit & Pull Request Guidelines

Recent history uses short, imperative summaries such as `Refresh styles and snippets UI`. Keep each commit narrowly scoped. Pull requests should explain user-visible behavior, list validation performed, link relevant issues, and include screenshots for SwiftUI changes. Call out new permissions, entitlements, provider credentials, or generated-project changes explicitly.
