import Foundation

public enum VocabularyNormalizer {
    /// A vocabulary list compiled into ready-to-run regular expressions, in application order.
    public struct CompiledVocabulary: Sendable {
        fileprivate let replacements: [(regex: NSRegularExpression, template: String)]
    }

    public static func compile(_ vocabulary: [VocabularyEntry]) -> CompiledVocabulary {
        compileCount += 1
        let replacements = vocabulary
            .filter(\.isEnabled)
            .sorted { $0.value.count > $1.value.count }
            .flatMap { entry in
                entry.variants.compactMap { variant -> (regex: NSRegularExpression, template: String)? in
                    guard !variant.isEmpty else { return nil }
                    guard let regex = try? NSRegularExpression(
                        pattern: "\\b\(NSRegularExpression.escapedPattern(for: variant))\\b",
                        options: [.caseInsensitive]
                    ) else { return nil }
                    return (regex, entry.value)
                }
            }
        return CompiledVocabulary(replacements: replacements)
    }

    public static func normalize(_ text: String, using compiled: CompiledVocabulary) -> String {
        compiled.replacements.reduce(text) { current, replacement in
            let range = NSRange(current.startIndex..., in: current)
            return replacement.regex.stringByReplacingMatches(
                in: current,
                range: range,
                withTemplate: replacement.template
            )
        }
    }

    public static func normalize(_ text: String, vocabulary: [VocabularyEntry]) -> String {
        normalize(text, using: cached(for: vocabulary))
    }

    // Small cache from a vocabulary's content to its compiled matchers, so repeated calls with
    // the same (unchanged) vocabulary don't recompile regular expressions every time.
    private static let cacheCapacity = 4
    nonisolated(unsafe) private static var cache: [Int: CompiledVocabulary] = [:]
    private static let cacheLock = NSLock()

    /// Number of times `compile(_:)` has actually built new matchers. Exposed for tests to
    /// verify the cache is being hit rather than recompiling on every call.
    internal nonisolated(unsafe) static var compileCount = 0

    private static func cached(for vocabulary: [VocabularyEntry]) -> CompiledVocabulary {
        let key = cacheKey(for: vocabulary)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[key] { return existing }
        let compiled = compile(vocabulary)
        if cache.count >= cacheCapacity { cache.removeAll() }
        cache[key] = compiled
        return compiled
    }

    private static func cacheKey(for vocabulary: [VocabularyEntry]) -> Int {
        var hasher = Hasher()
        for entry in vocabulary where entry.isEnabled {
            hasher.combine(entry.value)
            hasher.combine(entry.variants)
        }
        return hasher.finalize()
    }
}
