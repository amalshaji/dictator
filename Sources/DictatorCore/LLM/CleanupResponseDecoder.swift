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
        try CleanupSafetyValidator.validate(
            request: request,
            output: output,
            withdrawnSpans: payload.withdrawnSpans.map {
                CleanupSafetyValidator.WithdrawnSpan(
                    startUTF16: $0.startUTF16,
                    endUTF16: $0.endUTF16,
                    text: $0.text
                )
            },
            renderedSpans: payload.renderedSpans.map {
                CleanupSafetyValidator.RenderedSpan(
                    startUTF16: $0.startUTF16,
                    endUTF16: $0.endUTF16,
                    text: $0.text,
                    rendered: $0.rendered
                )
            }
        )
        return output
    }

    private struct Payload: Decodable {
        let intent: CleanupIntent
        let text: String
        let withdrawnSpans: [WithdrawnSpan]
        let renderedSpans: [RenderedSpan]

        private enum CodingKeys: String, CodingKey {
            case intent
            case text
            case withdrawnSpans
            case renderedSpans
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            intent = try container.decode(CleanupIntent.self, forKey: .intent)
            text = try container.decode(String.self, forKey: .text)
            withdrawnSpans = try container.decodeIfPresent([WithdrawnSpan].self, forKey: .withdrawnSpans) ?? []
            renderedSpans = try container.decodeIfPresent([RenderedSpan].self, forKey: .renderedSpans) ?? []
        }
    }

    private struct WithdrawnSpan: Decodable {
        let startUTF16: Int
        let endUTF16: Int
        let text: String
    }

    private struct RenderedSpan: Decodable {
        let startUTF16: Int
        let endUTF16: Int
        let text: String
        let rendered: String
    }
}
