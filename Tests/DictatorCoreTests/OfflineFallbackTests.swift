import Foundation
import XCTest
@testable import DictatorCore

final class OfflineFallbackTests: XCTestCase {
    func testOnlyConnectivityTransportErrorsQualifyForOfflineFallback() {
        let eligible: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .timedOut,
        ]

        for code in eligible {
            XCTAssertTrue(TransportFailureClassifier.isOfflineEligible(ProviderError.transport(code)))
        }
        XCTAssertFalse(TransportFailureClassifier.isOfflineEligible(ProviderError.transport(.secureConnectionFailed)))
        XCTAssertFalse(TransportFailureClassifier.isOfflineEligible(ProviderError.httpStatus(503, "Unavailable")))
        XCTAssertFalse(TransportFailureClassifier.isOfflineEligible(ProviderError.missingCredential("API key")))
    }

    func testContextualCleanupTransportFailureBecomesPlainOfflineDictation() async {
        let request = CleanupRequest(
            input: .contextual(spokenText: "replace this with a concise version", selectedText: "Long selected text"),
            vocabulary: []
        )

        let outcome = await CleanupCoordinator().cleanOrFallback(
            request: request,
            provider: FailingCleanupProvider(error: ProviderError.transport(.notConnectedToInternet)),
            model: "test",
            credentials: .init(apiKey: "test")
        )

        guard case .offlineFallback(let text, _) = outcome else {
            return XCTFail("Expected offline plain-dictation fallback")
        }
        XCTAssertEqual(text, "replace this with a concise version")
    }

    func testContextualCleanupProviderFailureStillProtectsSelection() async {
        let request = CleanupRequest(
            input: .contextual(spokenText: "replace this", selectedText: "Keep this safe"),
            vocabulary: []
        )

        let outcome = await CleanupCoordinator().cleanOrFallback(
            request: request,
            provider: FailingCleanupProvider(error: ProviderError.httpStatus(401, "Unauthorized")),
            model: "test",
            credentials: .init(apiKey: "test")
        )

        guard case .failed = outcome else {
            return XCTFail("Non-network failures must keep protecting selected text")
        }
    }

    func testTranscriptProcessorPreservesOfflineFallbackSignal() async {
        let result = await TranscriptProcessor().process(
            rawText: "plain offline dictation",
            selectedText: "Selected text",
            vocabulary: [],
            snippets: [],
            cleanup: .init(
                provider: FailingCleanupProvider(error: ProviderError.transport(.networkConnectionLost)),
                model: "test",
                credentials: .init(apiKey: "test")
            )
        )

        guard case .offlineFallback(let text, _) = result else {
            return XCTFail("Expected the app to receive the offline-mode signal")
        }
        XCTAssertEqual(text, "plain offline dictation")
    }
}

private struct FailingCleanupProvider: CleanupLLMProvider {
    let metadata = ProviderMetadata(
        kind: .groq,
        displayName: "Test",
        defaultModel: "test",
        models: ["test"],
        requiresAccountID: false
    )
    let error: any Error

    func validate(credentials: ProviderCredentials) async throws {}
    func listModels(credentials: ProviderCredentials) async throws -> [String] { [] }

    func clean(
        request: CleanupRequest,
        model: String,
        credentials: ProviderCredentials
    ) async throws -> CleanupResult {
        throw error
    }
}
