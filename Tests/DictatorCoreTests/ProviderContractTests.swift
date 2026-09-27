import Foundation
import XCTest
@testable import DictatorCore

final class ProviderContractTests: XCTestCase {
    private let audio = RecordedAudio(wavData: WAVEncoder.encodePCM16(Data(repeating: 0, count: 320)), duration: 0.01)

    func testGroqParsesTranscriptAndSendsVocabulary() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.host, "api.groq.com")
            let body = request.httpBody ?? Data()
            XCTAssertNotNil(body.range(of: Data("Dictator".utf8)))
            return (#"{"text":"Hello from Groq","x_groq":{"id":"req_1"}}"#.data(using: .utf8)!, 200)
        }
        let result = try await GroqSTTProvider(transport: transport).transcribe(
            audio: audio,
            options: .init(model: "whisper-large-v3-turbo", vocabulary: [.init(value: "Dictator")]),
            credentials: .init(apiKey: "test")
        )
        XCTAssertEqual(result.text, "Hello from Groq")
        XCTAssertEqual(result.requestID, "req_1")
    }

    func testDeepgramParsesNestedAlternative() async throws {
        let json = #"{"metadata":{"request_id":"dg_1"},"results":{"channels":[{"detected_language":"en","alternatives":[{"transcript":"Hello from Deepgram"}]}]}}"#
        let transport = MockTransport { request in
            XCTAssertTrue(request.url?.query?.contains("model=nova-3") == true)
            XCTAssertTrue(request.url?.query?.contains("detect_language=true") == true)
            XCTAssertFalse(request.url?.query?.contains("language=en") == true)
            return (json.data(using: .utf8)!, 200)
        }
        let result = try await DeepgramSTTProvider(transport: transport).transcribe(audio: audio, options: .init(model: "nova-3"), credentials: .init(apiKey: "test"))
        XCTAssertEqual(result.text, "Hello from Deepgram")
        XCTAssertEqual(result.language, "en")
    }

    func testDeepgramUsesExplicitLanguageInsteadOfDetection() async throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"Bonjour"}]}]}}"#
        let transport = MockTransport { request in
            XCTAssertTrue(request.url?.query?.contains("language=fr") == true)
            XCTAssertFalse(request.url?.query?.contains("detect_language") == true)
            return (json.data(using: .utf8)!, 200)
        }
        let result = try await DeepgramSTTProvider(transport: transport).transcribe(
            audio: audio,
            options: .init(model: "nova-3", language: "fr"),
            credentials: .init(apiKey: "test")
        )
        XCTAssertEqual(result.language, "fr")
    }

    func testOpenAICompatibleCleanupParsesJSONAndUsage() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"transcription\",\"text\":\"Ship Dictator 2.4 at https://example.com.\"}"}}],"usage":{"prompt_tokens":20,"completion_tokens":9}}"#
        let transport = MockTransport { _ in (response.data(using: .utf8)!, 200) }
        let provider = OpenAICompatibleCleanupProvider(
            kind: .groq,
            displayName: "Groq",
            defaultModel: "test",
            defaultBaseURL: URL(string: "https://example.com/v1")!,
            transport: transport
        )
        let result = try await provider.clean(
            request: .init(
                input: .transcription("Um ship Dictator 2.4 at https://example.com."),
                vocabulary: [.init(value: "Dictator")]
            ),
            model: "test",
            credentials: .init(apiKey: "test")
        )
        XCTAssertEqual(result.text, "Ship Dictator 2.4 at https://example.com.")
        XCTAssertEqual(result.inputTokens, 20)
    }

    func testGeminiCleanupSendsBearerAuthToOpenAICompatibleEndpoint() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"transcription\",\"text\":\"Hello Dictator.\"}"}}]}"#
        let transport = MockTransport { request in
            XCTAssertTrue(request.url?.path.hasSuffix("/v1beta/openai/chat/completions") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            return (response.data(using: .utf8)!, 200)
        }
        let result = try await OpenAICompatibleCleanupProvider.gemini(transport: transport).clean(
            request: .init(input: .transcription("Hello Dictator.")),
            model: "gemini-2.5-flash-lite",
            credentials: .init(apiKey: "test")
        )
        XCTAssertEqual(result.text, "Hello Dictator.")
    }

    func testOpenAICompatibleCleanupRoutesSelectedTextTransformation() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"transformation\",\"text\":\"hello world\"}"}}]}"#
        let transport = MockTransport { request in
            let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            XCTAssertTrue(body.contains("make it lowercase"))
            XCTAssertTrue(body.contains("HELLO WORLD"))
            return (response.data(using: .utf8)!, 200)
        }
        let provider = OpenAICompatibleCleanupProvider(
            kind: .groq,
            displayName: "Groq",
            defaultModel: "test",
            defaultBaseURL: URL(string: "https://example.com/v1")!,
            transport: transport
        )

        let result = try await provider.clean(
            request: .init(input: .contextual(spokenText: "make it lowercase", selectedText: "HELLO WORLD")),
            model: "test",
            credentials: .init(apiKey: "test")
        )

        XCTAssertEqual(result.intent, .transformation)
        XCTAssertEqual(result.text, "hello world")
    }

    func testCustomOpenAIProviderRequiresAnAbsoluteBaseURL() async {
        let provider = OpenAICompatibleCleanupProvider.custom(transport: MockTransport { _ in
            XCTFail("Invalid configuration must fail before making a request")
            return (Data(), 500)
        })

        do {
            _ = try await provider.listModels(credentials: .init(apiKey: "test"))
            XCTFail("Expected the missing base URL to be rejected")
        } catch {
            XCTAssertEqual(error as? ProviderError, .missingCredential("base URL"))
        }
    }

    func testCerebrasCleanupDefaultsToDocumentedModel() throws {
        let provider = try XCTUnwrap(CleanupProviderRegistry.provider(for: .cerebras))

        XCTAssertEqual(provider.metadata.displayName, "Cerebras")
        XCTAssertEqual(provider.metadata.defaultModel, "gpt-oss-120b")
    }

    func testOpenAICompatibleCleanupRequestsLowReasoningEffortForGptOssModels() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"transcription\",\"text\":\"Hi.\"}"}}]}"#
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.host, "api.cerebras.ai")
            let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            XCTAssertTrue(body.contains(#""reasoning_effort":"low""#))
            return (response.data(using: .utf8)!, 200)
        }

        _ = try await OpenAICompatibleCleanupProvider.cerebras(transport: transport).clean(
            request: .init(input: .transcription("Hi.")),
            model: "gpt-oss-120b",
            credentials: .init(apiKey: "test")
        )
    }

    func testOpenAICompatibleCleanupOmitsReasoningEffortForOtherModels() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"transcription\",\"text\":\"Hi.\"}"}}]}"#
        let transport = MockTransport { request in
            let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            XCTAssertFalse(body.contains("reasoning_effort"))
            return (response.data(using: .utf8)!, 200)
        }

        _ = try await OpenAICompatibleCleanupProvider.groq(transport: transport).clean(
            request: .init(input: .transcription("Hi.")),
            model: "llama-3.3-70b-versatile",
            credentials: .init(apiKey: "test")
        )
    }

    func testGroqWarmUpConnectionSendsHeadRequestToHost() async {
        let warmed = expectation(description: "Groq warm-up request sent")
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.host, "api.groq.com")
            warmed.fulfill()
            return (Data(), 200)
        }

        await GroqSTTProvider(transport: transport).warmUpConnection(credentials: .init(apiKey: "test"))

        await fulfillment(of: [warmed], timeout: 1)
    }

    func testGroqTranscribeRequestUsesTwentySecondTimeout() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.timeoutInterval, 20)
            return (#"{"text":"Hello"}"#.data(using: .utf8)!, 200)
        }
        _ = try await GroqSTTProvider(transport: transport).transcribe(
            audio: audio,
            options: .init(model: "whisper-large-v3-turbo"),
            credentials: .init(apiKey: "test")
        )
    }

    func testDeepgramWarmUpConnectionSendsHeadRequestToHost() async {
        let warmed = expectation(description: "Deepgram warm-up request sent")
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.host, "api.deepgram.com")
            warmed.fulfill()
            return (Data(), 200)
        }

        await DeepgramSTTProvider(transport: transport).warmUpConnection(credentials: .init(apiKey: "test"))

        await fulfillment(of: [warmed], timeout: 1)
    }

    func testDeepgramTranscribeRequestUsesTwentySecondTimeout() async throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"Hi"}]}]}}"#
        let transport = MockTransport { request in
            XCTAssertEqual(request.timeoutInterval, 20)
            return (json.data(using: .utf8)!, 200)
        }
        _ = try await DeepgramSTTProvider(transport: transport).transcribe(
            audio: audio,
            options: .init(model: "nova-3"),
            credentials: .init(apiKey: "test")
        )
    }

    func testWarmUpConnectionSendsHeadRequestToBaseURL() async {
        let warmed = expectation(description: "warm-up request sent")
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.host, "api.cerebras.ai")
            warmed.fulfill()
            return (Data(), 404)
        }

        await OpenAICompatibleCleanupProvider.cerebras(transport: transport)
            .warmUpConnection(credentials: .init(apiKey: "test"))

        await fulfillment(of: [warmed], timeout: 1)
    }

}

private struct MockTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, Int)
    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, status) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
