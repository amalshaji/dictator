import Foundation

/// Decodes an array element that may fail (e.g. a `TranscriptRecord` referencing a
/// retired `ProviderKind` such as "gladia") without failing the whole array decode.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public struct PersistedData: Codable, Equatable, Sendable {
    public var transcripts: [TranscriptRecord]
    public var lifetimeStatistics: LifetimeStatistics
    public var vocabulary: [VocabularyEntry]
    public var styles: [WritingStyle]
    public var snippets: [SnippetEntry]

    public init(transcripts: [TranscriptRecord] = [], lifetimeStatistics: LifetimeStatistics = LifetimeStatistics(), vocabulary: [VocabularyEntry] = [], styles: [WritingStyle] = [], snippets: [SnippetEntry] = []) {
        self.transcripts = transcripts
        self.lifetimeStatistics = lifetimeStatistics
        self.vocabulary = vocabulary
        self.styles = styles
        self.snippets = snippets
    }

    private enum CodingKeys: String, CodingKey { case transcripts, lifetimeStatistics, vocabulary, styles, snippets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let failableTranscripts = try values.decodeIfPresent([FailableDecodable<TranscriptRecord>].self, forKey: .transcripts) ?? []
        transcripts = failableTranscripts.compactMap(\.value)
        lifetimeStatistics = try values.decodeIfPresent(LifetimeStatistics.self, forKey: .lifetimeStatistics) ?? LifetimeStatistics()
        vocabulary = try values.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? []
        styles = try values.decodeIfPresent([WritingStyle].self, forKey: .styles) ?? []
        snippets = try values.decodeIfPresent([SnippetEntry].self, forKey: .snippets) ?? []
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
        self.encoder.outputFormatting = [.sortedKeys]
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
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(cleaned).write(to: fileURL, options: .atomic)
    }
}
