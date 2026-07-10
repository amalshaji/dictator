import Foundation

public struct PersistedData: Codable, Equatable, Sendable {
    public var transcripts: [TranscriptRecord]
    public var vocabulary: [VocabularyEntry]
    public var clipboard: [ClipboardEntry]
    public var styles: [WritingStyle]
    public var snippets: [SnippetEntry]

    public init(transcripts: [TranscriptRecord] = [], vocabulary: [VocabularyEntry] = [], clipboard: [ClipboardEntry] = [], styles: [WritingStyle] = [], snippets: [SnippetEntry] = []) {
        self.transcripts = transcripts
        self.vocabulary = vocabulary
        self.clipboard = clipboard
        self.styles = styles
        self.snippets = snippets
    }

    private enum CodingKeys: String, CodingKey { case transcripts, vocabulary, clipboard, styles, snippets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transcripts = try values.decodeIfPresent([TranscriptRecord].self, forKey: .transcripts) ?? []
        vocabulary = try values.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? []
        clipboard = try values.decodeIfPresent([ClipboardEntry].self, forKey: .clipboard) ?? []
        styles = try values.decodeIfPresent([WritingStyle].self, forKey: .styles) ?? []
        snippets = try values.decodeIfPresent([SnippetEntry].self, forKey: .snippets) ?? []
    }
}

public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var text: String
    public var rawText: String
    public var sourceBundleID: String?

    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, rawText: String, sourceBundleID: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.sourceBundleID = sourceBundleID
    }
}

public actor LocalStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func applicationSupportURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appending(path: "Dictator", directoryHint: .isDirectory).appending(path: "data.json")
    }

    public func load() throws -> PersistedData {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return PersistedData() }
        return try decoder.decode(PersistedData.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ data: PersistedData, now: Date = Date()) throws {
        var cleaned = data
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        cleaned.transcripts = Array(cleaned.transcripts.filter { $0.createdAt >= cutoff }.prefix(500))
        cleaned.clipboard = Array(cleaned.clipboard.filter { $0.createdAt >= cutoff }.prefix(50))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(cleaned).write(to: fileURL, options: .atomic)
    }
}
