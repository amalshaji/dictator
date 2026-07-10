import Foundation

public protocol SpeechToTextProvider: Sendable {
    var metadata: ProviderMetadata { get }
    func validate(credentials: ProviderCredentials) async throws
    func transcribe(audio: RecordedAudio, options: TranscriptionOptions, credentials: ProviderCredentials) async throws -> TranscriptionResult
}

public protocol CleanupLLMProvider: Sendable {
    var metadata: ProviderMetadata { get }
    func validate(credentials: ProviderCredentials) async throws
    func listModels(credentials: ProviderCredentials) async throws -> [String]
    func clean(request: CleanupRequest, model: String, credentials: ProviderCredentials) async throws -> CleanupResult
}

public struct CleanupPrompt: Sendable {
    public static func system(vocabulary: [VocabularyEntry], styleInstruction: String? = nil) -> String {
        let terms = vocabulary.filter(\.isEnabled).map(\.value)
        let vocabularyRule = terms.isEmpty
            ? ""
            : "\nPreserve these vocabulary terms exactly when they match the speech: \(terms.joined(separator: ", "))."
        let styleRule = styleInstruction
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : "\nWriting style: \($0). Apply only presentation changes; never change meaning." }
            ?? ""

        return """
        Rewrite dictated speech as clean written text.
        - Remove filler words, false starts, and accidental repetition.
        - Correct punctuation, capitalization, spacing, and obvious grammar.
        - Preserve meaning, tone, order, and level of detail.
        - Do not summarize, answer, elaborate, or add information.
        - Preserve URLs, email addresses, numbers, code, and identifiers exactly.
        - Return only JSON matching {"text":"<cleaned text>"}.
        \(vocabularyRule)
        \(styleRule)
        """
    }
}
