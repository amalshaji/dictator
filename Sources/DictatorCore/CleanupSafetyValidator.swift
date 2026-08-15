import Foundation

public enum CleanupSafetyValidator {
    public struct WithdrawnSpan: Equatable, Sendable {
        public let startUTF16: Int
        public let endUTF16: Int
        public let text: String

        public init(startUTF16: Int, endUTF16: Int, text: String) {
            self.startUTF16 = startUTF16
            self.endUTF16 = endUTF16
            self.text = text
        }
    }

    private static let protectedPatterns = [
        #"https?://[^\s]+"#,
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        #"\b\d+(?:[.,:/-]\d+)*%?\b"#,
        #"`[^`]+`"#
    ]

    private static let withdrawalCuePattern = #"^\s*(?:[.!?,;:—-]\s*)?(?:(?:i\s+)?(?:retract|withdraw)\s+(?:that|this|it|all\s+of\s+that|everything\s+i\s+(?:just\s+)?said|what\s+i\s+(?:just\s+)?said|(?:the\s+(?:last|previous)|that|this)\s+(?:statement|sentence|instruction))|i\s+(?:take|took)\s+back\s+(?:that|this|it|all\s+of\s+that|everything\s+i\s+(?:just\s+)?said|what\s+i\s+(?:just\s+)?said|(?:the\s+(?:last|previous)|that|this)\s+(?:statement|sentence|instruction))|i\s+(?:take|took)\s+(?:that|this|it|all\s+of\s+that|everything\s+i\s+(?:just\s+)?said|what\s+i\s+(?:just\s+)?said|(?:the\s+(?:last|previous)|that|this)\s+(?:statement|sentence|instruction))\s+back|scratch\s+that|forget\s+(?:that|this|it|everything\s+i\s+(?:just\s+)?said|what\s+i\s+(?:just\s+)?said)|disregard\s+(?:that|this|it|(?:the\s+(?:last|previous)|that|this)\s+(?:statement|sentence|instruction))|never\s+mind(?:\s+(?:that|this|it))?)\b(?=\s*(?:[.!?,;:—-]|$))"#
    private static let broadWithdrawalCuePattern = #"\b(?:all\s+of\s+that|everything\s+i\s+(?:just\s+)?said)\b"#
    private static let sentenceEndingPattern = #"[.!?](?=\s|$)"#

    public struct RenderedSpan: Equatable, Sendable {
        public let startUTF16: Int
        public let endUTF16: Int
        public let text: String
        public let rendered: String

        public init(startUTF16: Int, endUTF16: Int, text: String, rendered: String) {
            self.startUTF16 = startUTF16
            self.endUTF16 = endUTF16
            self.text = text
            self.rendered = rendered
        }
    }

    public static func validate(
        raw: String,
        cleaned: String,
        vocabulary: [VocabularyEntry],
        withdrawnSpans: [WithdrawnSpan] = [],
        renderedSpans: [RenderedSpan] = []
    ) throws {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.cleanupRejected("empty output") }
        guard !trimmed.contains("```") else { throw ProviderError.cleanupRejected("markdown fence") }

        let withdrawnRanges = try verifiedWithdrawnRanges(raw: raw, withdrawnSpans: withdrawnSpans)
        let renderedReplacements = try verifiedRenderedReplacements(raw: raw, cleaned: trimmed, spans: renderedSpans)
        try ensureNonOverlapping(withdrawnRanges + renderedReplacements.map(\.range))

        let removals = withdrawnRanges.map { (range: $0, replacement: "") }
        let baseline = replacing(raw: raw, replacements: removals)
        let convertedBaseline = replacing(
            raw: raw,
            replacements: removals + renderedReplacements.map { ($0.range, String($0.rendered)) }
        )
        let lowerRatio = Double(trimmed.count) / Double(max(convertedBaseline.count, 1))
        let upperRatio = Double(trimmed.count) / Double(max(baseline.count, 1))
        guard lowerRatio >= 0.45, upperRatio <= 1.65 else {
            throw ProviderError.cleanupRejected("unexpected length change")
        }

        for pattern in protectedPatterns {
            let rawValues = occurrenceCounts(matches(pattern, in: baseline))
            let cleanedValues = occurrenceCounts(matches(pattern, in: trimmed))
            guard rawValues.allSatisfy({ value, count in cleanedValues[value, default: 0] >= count }) else {
                throw ProviderError.cleanupRejected("protected token changed")
            }
        }

        for term in vocabulary.filter(\.isEnabled).map(\.value) where baseline.localizedCaseInsensitiveContains(term) {
            guard trimmed.localizedCaseInsensitiveContains(term) else {
                throw ProviderError.cleanupRejected("vocabulary term removed")
            }
        }
    }

    public static func validate(
        request: CleanupRequest,
        output: CleanupOutput,
        withdrawnSpans: [WithdrawnSpan] = [],
        renderedSpans: [RenderedSpan] = []
    ) throws {
        switch output {
        case .transcription(let text):
            try validate(
                raw: request.input.spokenText,
                cleaned: text,
                vocabulary: request.vocabulary,
                withdrawnSpans: withdrawnSpans,
                renderedSpans: renderedSpans
            )
        case .transformation(let text):
            guard withdrawnSpans.isEmpty else {
                throw ProviderError.cleanupRejected("transformation cannot withdraw source spans")
            }
            guard renderedSpans.isEmpty else {
                throw ProviderError.cleanupRejected("transformation cannot report rendered spans")
            }
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

    // The cleanup prompt allows rendering spoken symbol names ("underscore" -> "_") and emoji
    // names ("emoji red heart" -> a single emoji) as single characters, and requires the model
    // to report each conversion in renderedSpans. Every claimed span is verified locally —
    // exact source text at exact offsets, a plausible spoken name, and the rendered character
    // actually present in the cleaned output — before it may loosen the lower length bound.
    private static let spokenSymbolCharacters: [String: Character] = [
        "dot": ".", "underscore": "_", "dash": "-", "hyphen": "-", "slash": "/"
    ]

    private static func verifiedRenderedReplacements(
        raw: String,
        cleaned: String,
        spans: [RenderedSpan]
    ) throws -> [(range: Range<String.Index>, rendered: Character)] {
        guard !spans.isEmpty else { return [] }

        let rawUTF16Count = raw.utf16.count
        let replacements = try spans.map { span -> (range: Range<String.Index>, rendered: Character) in
            guard span.startUTF16 >= 0,
                  span.endUTF16 > span.startUTF16,
                  span.endUTF16 <= rawUTF16Count,
                  let range = Range(
                    NSRange(location: span.startUTF16, length: span.endUTF16 - span.startUTF16),
                    in: raw
                  ),
                  String(raw[range]) == span.text,
                  span.rendered.count == 1,
                  let rendered = span.rendered.first,
                  isAllowedRendering(source: span.text, rendered: rendered)
            else {
                throw ProviderError.cleanupRejected("invalid or unverified rendered span")
            }
            return (range, rendered)
        }

        let claimed = occurrenceCounts(replacements.map { String($0.rendered) })
        for (value, count) in claimed {
            guard cleaned.filter({ String($0) == value }).count >= count else {
                throw ProviderError.cleanupRejected("rendered character missing from output")
            }
        }
        return replacements
    }

    private static func isAllowedRendering(source: String, rendered: Character) -> Bool {
        let words = source.lowercased().split(whereSeparator: \.isWhitespace)
        if words.count == 1, let symbol = spokenSymbolCharacters[String(words[0])] {
            return rendered == symbol
        }
        return words.count <= 6
            && words.contains(where: { $0 == "emoji" })
            && isEmojiCharacter(rendered)
    }

    private static func isEmojiCharacter(_ character: Character) -> Bool {
        guard !character.isASCII else { return false }
        return character.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }

    private static func verifiedWithdrawnRanges(
        raw: String,
        withdrawnSpans: [WithdrawnSpan]
    ) throws -> [Range<String.Index>] {
        guard !withdrawnSpans.isEmpty else { return [] }

        let rawUTF16Count = raw.utf16.count
        return try withdrawnSpans.map { span -> Range<String.Index> in
            guard span.startUTF16 >= 0,
                  span.endUTF16 > span.startUTF16,
                  span.endUTF16 <= rawUTF16Count,
                  let range = Range(
                    NSRange(location: span.startUTF16, length: span.endUTF16 - span.startUTF16),
                    in: raw
                  ),
                  String(raw[range]) == span.text,
                  isSourceBoundary(range.lowerBound, in: raw),
                  let cueRange = withdrawalCue(after: range.upperBound, in: raw),
                  cueAllows(span.text, cue: String(raw[cueRange]))
            else {
                throw ProviderError.cleanupRejected("invalid or unverified withdrawn span")
            }
            return range.lowerBound..<cueRange.upperBound
        }
    }

    private static func ensureNonOverlapping(_ ranges: [Range<String.Index>]) throws {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where previous.upperBound > next.lowerBound {
            throw ProviderError.cleanupRejected("overlapping spans")
        }
    }

    private static func replacing(
        raw: String,
        replacements: [(range: Range<String.Index>, replacement: String)]
    ) -> String {
        var result = ""
        var cursor = raw.startIndex
        for (range, replacement) in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            result += raw[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        result += raw[cursor...]
        return result
    }

    private static func isSourceBoundary(_ index: String.Index, in raw: String) -> Bool {
        guard index != raw.startIndex else { return true }
        let prefix = String(raw[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preceding = prefix.last else { return true }
        return ".!?;:\n".contains(preceding)
    }

    private static func withdrawalCue(after index: String.Index, in raw: String) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(
            pattern: withdrawalCuePattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let searchRange = NSRange(index..., in: raw)
        guard let match = expression.firstMatch(in: raw, range: searchRange),
              match.range.location == searchRange.location,
              let range = Range(match.range, in: raw)
        else { return nil }
        return range
    }

    private static func cueAllows(_ withdrawnText: String, cue: String) -> Bool {
        let sentenceEndings = matches(sentenceEndingPattern, in: withdrawnText).count
        return sentenceEndings <= 1 || !matches(broadWithdrawalCuePattern, in: cue).isEmpty
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
