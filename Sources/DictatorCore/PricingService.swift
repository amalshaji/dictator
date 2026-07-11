import Foundation

public actor PricingService {
    public static let endpoint = URL(string: "https://models.dev/api.json")!

    private let cacheURL: URL
    private let transport: any HTTPTransport
    private let maxAge: TimeInterval
    private var snapshot: PricingSnapshot?

    public init(
        cacheURL: URL = PricingService.applicationSupportCacheURL(),
        transport: any HTTPTransport = URLSessionTransport(),
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        self.cacheURL = cacheURL
        self.transport = transport
        self.maxAge = maxAge
    }

    public static func applicationSupportCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Dictator", directoryHint: .isDirectory)
            .appending(path: "pricing.json")
    }

    public func current() -> PricingSnapshot? {
        if let snapshot { return snapshot }
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(PricingSnapshot.self, from: data)
        else { return nil }
        snapshot = cached
        return cached
    }

    @discardableResult
    public func refreshIfNeeded(force: Bool = false, now: Date = Date()) async throws -> PricingSnapshot {
        if !force, let current = current(), now.timeIntervalSince(current.fetchedAt) < maxAge {
            return current
        }
        let (data, response) = try await transport.data(for: URLRequest(url: Self.endpoint))
        try HTTPHelpers.requireSuccess(data: data, response: response)
        let fresh = PricingSnapshot(fetchedAt: now, rates: Self.withFallbacks(try Self.decodeRates(from: data)))
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fresh).write(to: cacheURL, options: .atomic)
        snapshot = fresh
        return fresh
    }

    public static func decodeRates(from data: Data) throws -> [String: ModelTokenRate] {
        let providers = try JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
        var result: [String: ModelTokenRate] = [:]
        for (providerID, provider) in providers {
            for (modelID, model) in provider.models {
                guard let input = model.cost?.input, let output = model.cost?.output else { continue }
                result["\(providerID)/\(modelID)"] = .init(inputPerMillion: input, outputPerMillion: output)
            }
        }
        return result
    }

    private static func withFallbacks(_ rates: [String: ModelTokenRate]) -> [String: ModelTokenRate] {
        PricingCatalog.fallbackRates.merging(rates) { _, live in live }
    }

    private struct ModelsDevProvider: Decodable { let models: [String: Model] }
    private struct Model: Decodable {
        let cost: Cost?
        struct Cost: Decodable { let input: Decimal?; let output: Decimal? }
    }
}
