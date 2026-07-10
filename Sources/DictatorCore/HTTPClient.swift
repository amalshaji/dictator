import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }
}

public enum HTTPHelpers {
    public static func requireHTTPURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else { throw ProviderError.invalidResponse }
        return url
    }

    public static func requireSuccess(data: Data, response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data.prefix(1_024), encoding: .utf8) ?? "Unknown error"
            throw ProviderError.httpStatus(response.statusCode, message)
        }
    }

    public static func multipartBody(
        fields: [String: String],
        fileField: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        boundary: String
    ) -> Data {
        multipartBody(fields: fields.sorted(by: { $0.key < $1.key }), fileField: fileField, filename: filename, mimeType: mimeType, fileData: fileData, boundary: boundary)
    }

    /// Pair-based variant supports APIs with repeatable multipart fields such as `keyterm`.
    public static func multipartBody(
        fields: [(String, String)],
        fileField: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        boundary: String
    ) -> Data {
        var data = Data()
        for (name, value) in fields {
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        data.append("\r\n--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}
