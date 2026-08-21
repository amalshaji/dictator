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

    public struct CorrectionSpan: Equatable, Sendable {
        public let startUTF16: Int
        public let endUTF16: Int
        public let text: String
        public let replacementStartUTF16: Int
        public let replacementEndUTF16: Int
        public let replacementText: String

        public init(
            startUTF16: Int,
            endUTF16: Int,
            text: String,
            replacementStartUTF16: Int,
            replacementEndUTF16: Int,
            replacementText: String
        ) {
            self.startUTF16 = startUTF16
            self.endUTF16 = endUTF16
            self.text = text
            self.replacementStartUTF16 = replacementStartUTF16
            self.replacementEndUTF16 = replacementEndUTF16
            self.replacementText = replacementText
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
        correctionSpans: [CorrectionSpan] = [],
        renderedSpans: [RenderedSpan] = []
    ) throws {
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.cleanupRejected("empty output") }
        guard !trimmed.contains("```") else { throw ProviderError.cleanupRejected("markdown fence") }

        let withdrawnRanges = try verifiedWithdrawnRanges(raw: raw, withdrawnSpans: withdrawnSpans)
        let correctionReplacements = try verifiedCorrectionReplacements(
            raw: raw,
            cleaned: trimmed,
            spans: correctionSpans
        )
        let renderedReplacements = try verifiedRenderedReplacements(raw: raw, cleaned: trimmed, spans: renderedSpans)
        try ensureNonOverlapping(
            withdrawnRanges + correctionReplacements.map(\.range) + renderedReplacements.map(\.range)
        )

        let semanticReplacements = withdrawnRanges.map { (range: $0, replacement: "") }
            + correctionReplacements
        let baseline = replacing(raw: raw, replacements: semanticReplacements)
        let convertedBaseline = replacing(
            raw: raw,
            replacements: semanticReplacements + renderedReplacements
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
        correctionSpans: [CorrectionSpan] = [],
        renderedSpans: [RenderedSpan] = []
    ) throws {
        switch output {
        case .transcription(let text):
            try validate(
                raw: request.input.spokenText,
                cleaned: text,
                vocabulary: request.vocabulary,
                withdrawnSpans: withdrawnSpans,
                correctionSpans: correctionSpans,
                renderedSpans: renderedSpans
            )
        case .transformation(let text):
            guard withdrawnSpans.isEmpty else {
                throw ProviderError.cleanupRejected("transformation cannot withdraw source spans")
            }
            guard correctionSpans.isEmpty else {
                throw ProviderError.cleanupRejected("transformation cannot report correction spans")
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

    // The cleanup prompt allows rendering spoken symbol names, comparison phrases, and emoji
    // names as compact written tokens. Every claimed span is verified locally — exact source
    // text at exact offsets, an allowlisted rendering, and the rendered value actually present
    // in the cleaned output — before it may loosen the lower length bound.
    private static let spokenSymbolRenderings: [String: String] = [
        "dot": ".", "underscore": "_", "dash": "-", "hyphen": "-", "slash": "/"
    ]
    private static let spokenComparisonRenderings: [String: String] = [
        "greater than or equal to": ">=",
        "greater than or equals": ">=",
        "greater there or equal to": ">=",
        "less than or equal to": "<=",
        "less than or equals": "<=",
        "greater than": ">",
        "less than": "<",
        "not equal to": "!=",
        "not equals": "!=",
        "equal to": "=",
        "equals": "="
    ]

    private static func verifiedRenderedReplacements(
        raw: String,
        cleaned: String,
        spans: [RenderedSpan]
    ) throws -> [(range: Range<String.Index>, replacement: String)] {
        guard !spans.isEmpty else { return [] }

        let rawUTF16Count = raw.utf16.count
        let replacements = try spans.map { span -> (range: Range<String.Index>, replacement: String) in
            guard span.startUTF16 >= 0,
                  span.endUTF16 > span.startUTF16,
                  span.endUTF16 <= rawUTF16Count,
                  let range = Range(
                    NSRange(location: span.startUTF16, length: span.endUTF16 - span.startUTF16),
                    in: raw
                  ),
                  String(raw[range]) == span.text,
                  isAllowedRendering(source: span.text, rendered: span.rendered)
            else {
                throw ProviderError.cleanupRejected("invalid or unverified rendered span")
            }
            return (range, span.rendered)
        }

        let claimed = occurrenceCounts(replacements.map(\.replacement))
        for (value, count) in claimed {
            let pattern = NSRegularExpression.escapedPattern(for: value)
            guard matches(pattern, in: cleaned).count >= count else {
                throw ProviderError.cleanupRejected("rendered value missing from output")
            }
        }
        return replacements
    }

    private static func isAllowedRendering(source: String, rendered: String) -> Bool {
        let phrase = source.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        if let symbol = spokenSymbolRenderings[phrase] {
            return rendered == symbol
        }
        if let comparison = spokenComparisonRenderings[phrase] {
            return rendered == comparison
        }
        let words = phrase.split(whereSeparator: \.isWhitespace)
        return rendered.count == 1
            && words.count <= 6
            && words.contains(where: { $0 == "emoji" })
            && rendered.first.map(isEmojiCharacter) == true
    }

    private static func isEmojiCharacter(_ character: Character) -> Bool {
        guard !character.isASCII else { return false }
        return character.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }

    private static func verifiedCorrectionReplacements(
        raw: String,
        cleaned: String,
        spans: [CorrectionSpan]
    ) throws -> [(range: Range<String.Index>, replacement: String)] {
        guard !spans.isEmpty else { return [] }

        let rawUTF16Count = raw.utf16.count
        let replacements = try spans.map { span -> (range: Range<String.Index>, replacement: String) in
            guard span.startUTF16 >= 0,
                  span.endUTF16 > span.startUTF16,
                  span.replacementStartUTF16 > span.endUTF16,
                  span.replacementEndUTF16 > span.replacementStartUTF16,
                  span.replacementEndUTF16 <= rawUTF16Count,
                  span.replacementEndUTF16 - span.startUTF16 <= 240,
                  let abandonedRange = Range(
                    NSRange(location: span.startUTF16, length: span.endUTF16 - span.startUTF16),
                    in: raw
                  ),
                  let replacementRange = Range(
                    NSRange(
                        location: span.replacementStartUTF16,
                        length: span.replacementEndUTF16 - span.replacementStartUTF16
                    ),
                    in: raw
                  ),
                  String(raw[abandonedRange]) == span.text,
                  String(raw[replacementRange]) == span.replacementText,
                  !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !span.replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isPhraseBoundary(abandonedRange, in: raw),
                  isPhraseBoundary(replacementRange, in: raw)
            else {
                throw ProviderError.cleanupRejected("invalid or unverified correction span")
            }

            let cue = raw[abandonedRange.upperBound..<replacementRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cue.isEmpty,
                  cue.utf16.count <= 80,
                  isVerifiedCorrectionCue(cue)
            else {
                throw ProviderError.cleanupRejected("invalid or unverified correction span")
            }

            return (abandonedRange.lowerBound..<replacementRange.upperBound, span.replacementText)
        }

        let claimed = occurrenceCounts(replacements.map(\.replacement))
        for (value, count) in claimed {
            let pattern = NSRegularExpression.escapedPattern(for: value)
            guard matches(pattern, in: cleaned).count >= count else {
                throw ProviderError.cleanupRejected("correction replacement missing from output")
            }
        }
        return replacements
    }

    private static func isVerifiedCorrectionCue(_ cue: String) -> Bool {
        if !matches(withdrawalCuePattern, in: cue).isEmpty {
            return true
        }

        let words = cue.lowercased().split(whereSeparator: { !$0.isLetter })
        if words.count == 1, words[0] == "correction" {
            return true
        }
        return zip(words, words.dropFirst()).contains { $0 == $1 }
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

    private static func isPhraseBoundary(_ range: Range<String.Index>, in raw: String) -> Bool {
        let beginsAtBoundary: Bool
        if range.lowerBound == raw.startIndex {
            beginsAtBoundary = true
        } else {
            let preceding = raw[raw.index(before: range.lowerBound)]
            beginsAtBoundary = !preceding.isLetter && !preceding.isNumber
        }

        let endsAtBoundary: Bool
        if range.upperBound == raw.endIndex {
            endsAtBoundary = true
        } else {
            let following = raw[range.upperBound]
            endsAtBoundary = !following.isLetter && !following.isNumber
        }
        return beginsAtBoundary && endsAtBoundary
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
