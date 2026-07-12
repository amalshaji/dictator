import XCTest
@testable import DictatorCore

final class PricingCatalogTests: XCTestCase {
    func testAppleSpeechHasZeroBillableCost() {
        XCTAssertEqual(
            PricingCatalog.estimatedSTTCost(
                provider: .appleSpeech,
                model: AppleTranscriptionEngine.speechTranscriber.rawValue,
                audioSeconds: 60
            ),
            0
        )
    }

    func testCatalogUsesAudioDurationAndMinimumBilling() {
        XCTAssertEqual(PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 3_600), Decimal(string: "0.04"))
        XCTAssertEqual(PricingCatalog.estimatedSTTCost(provider: .xAI, model: "grok-transcribe", audioSeconds: 1_800), Decimal(string: "0.05"))
        XCTAssertEqual(
            PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 1),
            PricingCatalog.estimatedSTTCost(provider: .groq, model: "whisper-large-v3-turbo", audioSeconds: 10)
        )
    }

    func testUnknownSTTModelHasNoEstimatedCost() {
        XCTAssertNil(PricingCatalog.estimatedSTTCost(provider: .groq, model: "unknown", audioSeconds: 60))
        XCTAssertNil(PricingCatalog.estimatedSTTCost(provider: .deepgram, model: "future-model", audioSeconds: 60))
    }

    func testModelsDevPricingDecodesExactProviderAndModel() throws {
        let data = #"{"groq":{"models":{"openai/gpt-oss-20b":{"cost":{"input":0.1,"output":0.5}}}}}"#.data(using: .utf8)!
        let rates = try PricingService.decodeRates(from: data)
        XCTAssertEqual(rates["groq/openai/gpt-oss-20b"], .init(inputPerMillion: 0.1, outputPerMillion: 0.5))
        XCTAssertNil(PricingCatalog.estimatedLLMCost(provider: .groq, model: "similar-model", usage: .init(inputTokens: 10), rates: rates))
        XCTAssertEqual(PricingCatalog.estimatedLLMCost(provider: .groq, model: "openai/gpt-oss-20b", usage: .init(inputTokens: 1_000_000, outputTokens: 1_000_000), rates: rates), Decimal(string: "0.6"))
        XCTAssertEqual(PricingCatalog.estimatedLLMCost(provider: .groq, model: "openai/gpt-oss-20b", usage: .init(providerReportedCostUSD: 2), rates: rates), 2)
    }

    func testProviderReportedCostWorksWithoutTokens() {
        XCTAssertEqual(PricingCatalog.estimatedLLMCost(provider: .openAICompatible, model: "custom", usage: .init(providerReportedCostUSD: 0.25), rates: [:]), Decimal(string: "0.25"))
    }

    func testServiceUsesFreshDiskCacheWithoutNetwork() async throws {
        let cache = try makeCache()
        let expected = PricingSnapshot(fetchedAt: Date(), rates: ["groq/test": .init(inputPerMillion: 1, outputPerMillion: 2)])
        try JSONEncoder().encode(expected).write(to: cache)
        let service = PricingService(cacheURL: cache, transport: PricingTransport(result: .failure(ProviderError.invalidResponse)))
        let actual = try await service.refreshIfNeeded()
        XCTAssertEqual(actual, expected)
    }

    func testServiceRefreshesThroughInjectedTransportAndRetainsCacheAfterFailure() async throws {
        let cache = try makeCache()
        let data = #"{"groq":{"models":{"live":{"cost":{"input":1,"output":2}}}}}"#.data(using: .utf8)!
        let success = PricingService(cacheURL: cache, transport: PricingTransport(result: .success(data)), maxAge: 0)
        let refreshed = try await success.refreshIfNeeded(force: true, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(refreshed.rates["groq/live"], .init(inputPerMillion: 1, outputPerMillion: 2))

        let failure = PricingService(cacheURL: cache, transport: PricingTransport(result: .failure(ProviderError.invalidResponse)), maxAge: 0)
        do {
            _ = try await failure.refreshIfNeeded(force: true)
            XCTFail("Expected refresh failure")
        } catch {}
        let retained = await failure.current()
        XCTAssertEqual(retained, refreshed)
    }

    private func makeCache() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "pricing.json")
    }
}

private struct PricingTransport: HTTPTransport {
    let result: Result<Data, Error>

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = try result.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
