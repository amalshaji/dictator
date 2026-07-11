import Foundation

public enum CleanupSafetyValidator {
    private static let protectedPatterns = [
        #"https?://[^\s]+"#,
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        #"\b\d+(?:[.,:/-]\d+)*%?\b"#,
        #"`[^`]+`"#
    ]

    public static func validate(raw: String, cleaned: String, vocabulary: [VocabularyEntry]) throws {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.cleanupRejected("empty output") }
        guard !trimmed.contains("```") else { throw ProviderError.cleanupRejected("markdown fence") }

        let ratio = Double(trimmed.count) / Double(max(raw.count, 1))
        guard (0.45...1.65).contains(ratio) else {
            throw ProviderError.cleanupRejected("unexpected length change")
        }

        for pattern in protectedPatterns {
            let rawValues = occurrenceCounts(matches(pattern, in: raw))
            let cleanedValues = occurrenceCounts(matches(pattern, in: trimmed))
            guard rawValues.allSatisfy({ value, count in cleanedValues[value, default: 0] >= count }) else {
                throw ProviderError.cleanupRejected("protected token changed")
            }
        }

        for term in vocabulary.filter(\.isEnabled).map(\.value) where raw.localizedCaseInsensitiveContains(term) {
            guard trimmed.localizedCaseInsensitiveContains(term) else {
                throw ProviderError.cleanupRejected("vocabulary term removed")
            }
        }
    }

    public static func validate(request: CleanupRequest, output: CleanupOutput) throws {
        switch output {
        case .transcription(let text):
            try validate(raw: request.input.spokenText, cleaned: text, vocabulary: request.vocabulary)
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

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func occurrenceCounts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in counts[value, default: 0] += 1 }
    }
}
