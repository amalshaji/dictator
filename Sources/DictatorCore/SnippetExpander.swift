import Foundation

public enum SnippetExpander {
    public static func expand(_ text: String, snippets: [SnippetEntry]) -> String {
        var result = text
        let active = snippets.filter { $0.isEnabled && !$0.trigger.isEmpty }.sorted { $0.trigger.count > $1.trigger.count }
        for snippet in active {
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])") else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion))
        }
        return result
    }
}
