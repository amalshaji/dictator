import Foundation
import XCTest
@testable import DictatorCore

final class ProviderContractTests: XCTestCase {
    private let audio = RecordedAudio(wavData: WAVEncoder.encodePCM16(Data(repeating: 0, count: 320)), pcm16Data: Data(repeating: 0, count: 320), duration: 0.01)

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
        let json = #"{"metadata":{"request_id":"dg_1"},"results":{"channels":[{"alternatives":[{"transcript":"Hello from Deepgram","languages":["en"]}]}]}}"#
        let transport = MockTransport { request in
            XCTAssertTrue(request.url?.query?.contains("model=nova-3") == true)
            return (json.data(using: .utf8)!, 200)
        }
        let result = try await DeepgramSTTProvider(transport: transport).transcribe(audio: audio, options: .init(model: "nova-3"), credentials: .init(apiKey: "test"))
        XCTAssertEqual(result.text, "Hello from Deepgram")
        XCTAssertEqual(result.language, "en")
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
        let response = #"{"choices":[{"message":{"content":"{\"text\":\"Ship Dictator 2.4 at https://example.com.\"}"}}],"usage":{"prompt_tokens":20,"completion_tokens":9}}"#
        let transport = MockTransport { _ in (response.data(using: .utf8)!, 200) }
        let provider = OpenAICompatibleCleanupProvider(
            kind: .groq,
            displayName: "Groq",
            defaultModel: "test",
            defaultBaseURL: URL(string: "https://example.com/v1")!,
            transport: transport
        )
        let result = try await provider.clean(
            request: .init(transcript: "Um ship Dictator 2.4 at https://example.com.", vocabulary: [.init(value: "Dictator")]),
            model: "test",
            credentials: .init(apiKey: "test")
        )
        XCTAssertEqual(result.text, "Ship Dictator 2.4 at https://example.com.")
        XCTAssertEqual(result.inputTokens, 20)
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
