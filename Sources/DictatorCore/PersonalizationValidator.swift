import Foundation

public enum PersonalizationValidationError: LocalizedError, Equatable, Sendable {
    case emptyValue(String)
    case duplicateValue(String)

    public var errorDescription: String? {
        switch self {
        case .emptyValue(let field): "\(field) cannot be empty."
        case .duplicateValue(let value): "“\(value)” is already in use."
        }
    }
}

public enum PersonalizationValidator {
    public static func normalizedVariants(_ variants: [String]) -> [String] {
        var seen = Set<String>()
        return variants.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    public static func validateVocabulary(_ candidate: VocabularyEntry, among entries: [VocabularyEntry]) throws -> VocabularyEntry {
        var candidate = candidate
        candidate.value = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.value.isEmpty else { throw PersonalizationValidationError.emptyValue("Vocabulary term") }
        candidate.variants = normalizedVariants(candidate.variants).filter { $0.caseInsensitiveCompare(candidate.value) != .orderedSame }
        let candidateKeys = Set(([candidate.value] + candidate.variants).map { $0.lowercased() })
        let existingKeys = Set(entries.filter { $0.id != candidate.id }.flatMap { [$0.value] + $0.variants }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if let collision = candidateKeys.intersection(existingKeys).first {
            throw PersonalizationValidationError.duplicateValue(collision)
        }
        return candidate
    }

    public static func validateStyle(_ candidate: WritingStyle, among styles: [WritingStyle]) throws -> WritingStyle {
        var candidate = candidate
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.instruction = candidate.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.name.isEmpty else { throw PersonalizationValidationError.emptyValue("Style name") }
        guard !candidate.instruction.isEmpty else { throw PersonalizationValidationError.emptyValue("Style instructions") }
        guard !styles.contains(where: { $0.id != candidate.id && $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame }) else {
            throw PersonalizationValidationError.duplicateValue(candidate.name)
        }
        return candidate
    }

    public static func validateSnippet(_ candidate: SnippetEntry, among snippets: [SnippetEntry]) throws -> SnippetEntry {
        var candidate = candidate
        candidate.trigger = candidate.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.expansion = candidate.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.trigger.isEmpty else { throw PersonalizationValidationError.emptyValue("Snippet trigger") }
        guard !candidate.expansion.isEmpty else { throw PersonalizationValidationError.emptyValue("Snippet replacement") }
        guard !snippets.contains(where: { $0.id != candidate.id && $0.trigger.caseInsensitiveCompare(candidate.trigger) == .orderedSame }) else {
            throw PersonalizationValidationError.duplicateValue(candidate.trigger)
        }
        return candidate
    }
}
