import Foundation

/// Cheap sanity checks on LLM cleanup output. The cleanup prompt rewrites dictation
/// semantically (drops fillers and retracted speech, regroups points, adds lists), so the
/// output is not expected to align with the raw text; these checks only catch responses
/// that are clearly not a rewrite of it.
public enum CleanupSafetyValidator {
    public static func validate(raw: String, cleaned: String) throws {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.cleanupRejected("empty output") }
        guard !trimmed.contains("```") else { throw ProviderError.cleanupRejected("markdown fence") }
        // List markers and line breaks add some length to short dictation; anything far
        // beyond that means the model answered or elaborated instead of rewriting.
        guard trimmed.count <= raw.count * 2 + 20 else {
            throw ProviderError.cleanupRejected("unexpected length change")
        }
    }

    public static func validate(request: CleanupRequest, output: CleanupOutput) throws {
        switch output {
        case .transcription(let text):
            try validate(raw: request.input.spokenText, cleaned: text)
        case .transformation(let text):
            guard case .contextual(_, let selectedText) = request.input, !selectedText.isEmpty else {
                throw ProviderError.cleanupRejected("transformation requires selected text")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ProviderError.cleanupRejected("empty output") }
            guard trimmed.count <= max(selectedText.count * 8, selectedText.count + 4_000) else {
                throw ProviderError.cleanupRejected("unexpected length change")
            }
        }
    }
}
