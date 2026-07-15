import Foundation

public enum ScreenAwareResponseDecoder {
    public static func decode(_ content: String, selectedText: String?) throws -> (ScreenAwareIntent, String) {
        guard let data = content.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw ProviderError.invalidResponse }

        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { throw ProviderError.invalidResponse }
        let hasSelection = selectedText?.isEmpty == false
        switch payload.intent {
        case .insert where hasSelection, .replaceSelection where !hasSelection:
            throw ProviderError.invalidResponse
        case .insert, .replaceSelection:
            return (payload.intent, text)
        }
    }

    private struct Payload: Decodable {
        let intent: ScreenAwareIntent
        let text: String
    }
}
