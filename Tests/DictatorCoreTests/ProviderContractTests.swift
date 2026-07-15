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

    func testXAIUsesRepeatableKeytermFields() async throws {
        let transport = MockTransport { request in
            let body = request.httpBody ?? Data()
            let marker = Data("name=\"keyterm\"".utf8)
            XCTAssertEqual(body.ranges(of: marker).count, 2)
            return (#"{"text":"Dictator and Roughdraft","language":"en"}"#.data(using: .utf8)!, 200)
        }
        let result = try await XAISTTProvider(transport: transport).transcribe(
            audio: audio,
            options: .init(model: "grok-transcribe", vocabulary: [.init(value: "Dictator"), .init(value: "Roughdraft")]),
            credentials: .init(apiKey: "test")
        )
        XCTAssertEqual(result.text, "Dictator and Roughdraft")
    }

    func testOpenAICompatibleCleanupParsesJSONAndUsage() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"transcription\",\"text\":\"Ship Dictator 2.4 at https://example.com.\"}"}}],"usage":{"prompt_tokens":20,"completion_tokens":9,"cost":0.004}}"#
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
        XCTAssertEqual(result.providerReportedCostUSD, Decimal(string: "0.004"))
    }

    func testCloudflareCleanupParsesUsage() async throws {
        let response = #"{"result":{"response":"{\"intent\":\"transcription\",\"text\":\"Hello Dictator.\"}","usage":{"prompt_tokens":12,"completion_tokens":4}}}"#
        let provider = CloudflareCleanupProvider(transport: MockTransport { _ in (response.data(using: .utf8)!, 200) })
        let result = try await provider.clean(
            request: .init(input: .transcription("Hello Dictator."), vocabulary: [.init(value: "Dictator")]),
            model: "test",
            credentials: .init(apiKey: "test", accountID: "account")
        )
        XCTAssertEqual(result.inputTokens, 12); XCTAssertEqual(result.outputTokens, 4)
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

    func testOpenAICompatibleScreenAwareSendsImageAndParsesInsertResult() async throws {
        let response = #"{"choices":[{"message":{"content":"{\"intent\":\"insert\",\"text\":\"Thanks — Tuesday works for me.\"}"}}],"usage":{"prompt_tokens":42,"completion_tokens":8}}"#
        let transport = MockTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let user = try XCTUnwrap(messages.last)
            let content = try XCTUnwrap(user["content"] as? [[String: Any]])
            XCTAssertEqual(content.compactMap { $0["type"] as? String }, ["text", "image_url"])
            let image = try XCTUnwrap(content.last?["image_url"] as? [String: Any])
            XCTAssertEqual(image["url"] as? String, "data:image/jpeg;base64,/9g=")
            return (response.data(using: .utf8)!, 200)
        }
        let provider = OpenAICompatibleScreenAwareProvider(
            kind: .groq,
            displayName: "Groq",
            defaultModel: "vision-test",
            defaultBaseURL: URL(string: "https://example.com/v1")!,
            transport: transport
        )

        let result = try await provider.generate(
            request: ScreenAwareRequest(
                command: "Reply that Tuesday works",
                imageData: Data([0xff, 0xd8]),
                imageMIMEType: "image/jpeg",
                applicationName: "Mail",
                bundleIdentifier: "com.apple.mail",
                windowTitle: "Project update"
            ),
            model: "vision-test",
            credentials: .init(apiKey: "test")
        )

        XCTAssertEqual(result.intent, .insert)
        XCTAssertEqual(result.text, "Thanks — Tuesday works for me.")
        XCTAssertEqual(result.inputTokens, 42)
    }

    func testGeminiScreenAwareSendsInlineImageAndParsesSelectionReplacement() async throws {
        let response = #"{"candidates":[{"content":{"parts":[{"text":"{\"intent\":\"replaceSelection\",\"text\":\"Concise copy\"}"}]}}],"usageMetadata":{"promptTokenCount":21,"candidatesTokenCount":4}}"#
        let transport = MockTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            let inlineData = try XCTUnwrap(parts.last?["inlineData"] as? [String: Any])
            XCTAssertEqual(inlineData["mimeType"] as? String, "image/jpeg")
            XCTAssertEqual(inlineData["data"] as? String, "/9g=")
            return (response.data(using: .utf8)!, 200)
        }

        let result = try await GeminiScreenAwareProvider(transport: transport).generate(
            request: ScreenAwareRequest(
                command: "Make this concise",
                imageData: Data([0xff, 0xd8]),
                imageMIMEType: "image/jpeg",
                selectedText: "A long paragraph"
            ),
            model: "gemini-2.5-flash-lite",
            credentials: .init(apiKey: "test")
        )

        XCTAssertEqual(result.intent, .replaceSelection)
        XCTAssertEqual(result.text, "Concise copy")
        XCTAssertEqual(result.outputTokens, 4)
    }

    func testScreenAwareDecoderRejectsSelectionReplacementWithoutCapturedSelection() throws {
        XCTAssertThrowsError(
            try ScreenAwareResponseDecoder.decode(
                #"{"intent":"replaceSelection","text":"Unsafe"}"#,
                selectedText: nil
            )
        ) { error in
            XCTAssertEqual(error as? ProviderError, .invalidResponse)
        }
    }
}


private extension Data {
    func ranges(of needle: Data) -> [Range<Data.Index>] {
        var result: [Range<Data.Index>] = []
        var start = startIndex
        while start < endIndex, let range = self[start...].range(of: needle) {
            result.append(range)
            start = range.upperBound
        }
        return result
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
