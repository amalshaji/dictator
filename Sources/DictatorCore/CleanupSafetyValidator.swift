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
            let rawValues = matches(pattern, in: raw)
            let cleanedValues = matches(pattern, in: trimmed)
            guard Set(rawValues).isSubset(of: Set(cleanedValues)) else {
                throw ProviderError.cleanupRejected("protected token changed")
            }
        }

        for term in vocabulary.filter(\.isEnabled).map(\.value) where raw.localizedCaseInsensitiveContains(term) {
            guard trimmed.localizedCaseInsensitiveContains(term) else {
                throw ProviderError.cleanupRejected("vocabulary term removed")
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
}

