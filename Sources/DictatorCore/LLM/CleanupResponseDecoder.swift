import Foundation

enum CleanupResponseDecoder {
    static func decode(_ content: String, for request: CleanupRequest) throws -> CleanupOutput {
        guard let data = content.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw ProviderError.invalidResponse }

        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let output: CleanupOutput = switch payload.intent {
        case .transcription: .transcription(text)
        case .transformation: .transformation(text)
        }
        try CleanupSafetyValidator.validate(request: request, output: output)
        return output
    }

    private struct Payload: Decodable {
        let intent: CleanupIntent
        let text: String
    }
}
