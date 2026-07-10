import Foundation

public enum VocabularyNormalizer {
    public static func normalize(_ text: String, vocabulary: [VocabularyEntry]) -> String {
        vocabulary
            .filter(\.isEnabled)
            .sorted { $0.value.count > $1.value.count }
            .reduce(text) { current, entry in
                entry.variants.reduce(current) { result, variant in
                    guard !variant.isEmpty else { return result }
                    return result.replacingOccurrences(
                        of: "\\b\(NSRegularExpression.escapedPattern(for: variant))\\b",
                        with: entry.value,
                        options: [.regularExpression, .caseInsensitive]
                    )
                }
            }
    }
}

