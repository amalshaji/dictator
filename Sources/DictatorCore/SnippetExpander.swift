import Foundation

public enum SnippetExpander {
    /// A snippet list compiled into ready-to-run regular expressions, longest trigger first.
    public struct CompiledSnippets: Sendable {
        fileprivate let replacements: [(regex: NSRegularExpression, template: String)]
    }

    public static func compile(_ snippets: [SnippetEntry]) -> CompiledSnippets {
        compileCount += 1
        let active = snippets.filter { $0.isEnabled && !$0.trigger.isEmpty }.sorted { $0.trigger.count > $1.trigger.count }
        let replacements = active.compactMap { snippet -> (regex: NSRegularExpression, template: String)? in
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])") else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: snippet.expansion))
        }
        return CompiledSnippets(replacements: replacements)
    }

    public static func expand(_ text: String, using compiled: CompiledSnippets) -> String {
        var result = text
        for replacement in compiled.replacements {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = replacement.regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement.template)
        }
        return result
    }

    public static func expand(_ text: String, snippets: [SnippetEntry]) -> String {
        expand(text, using: cached(for: snippets))
    }

    // Small cache from a snippet list's content to its compiled matchers, so repeated calls with
    // the same (unchanged) snippets don't recompile regular expressions every time.
    private static let cacheCapacity = 4
    nonisolated(unsafe) private static var cache: [Int: CompiledSnippets] = [:]
    private static let cacheLock = NSLock()

    /// Number of times `compile(_:)` has actually built new matchers. Exposed for tests to
    /// verify the cache is being hit rather than recompiling on every call.
    internal nonisolated(unsafe) static var compileCount = 0

    private static func cached(for snippets: [SnippetEntry]) -> CompiledSnippets {
        let key = cacheKey(for: snippets)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[key] { return existing }
        let compiled = compile(snippets)
        if cache.count >= cacheCapacity { cache.removeAll() }
        cache[key] = compiled
        return compiled
    }

    private static func cacheKey(for snippets: [SnippetEntry]) -> Int {
        var hasher = Hasher()
        for snippet in snippets where snippet.isEnabled && !snippet.trigger.isEmpty {
            hasher.combine(snippet.trigger)
            hasher.combine(snippet.expansion)
        }
        return hasher.finalize()
    }
}
