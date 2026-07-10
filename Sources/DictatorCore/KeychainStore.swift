import Foundation
import Security

public struct KeychainStore: Sendable {
    private let service: String
    public init(service: String = "ai.dictator.credentials") { self.service = service }

    public func save(_ credentials: ProviderCredentials, for purpose: String, provider: ProviderKind) throws {
        let account = "\(purpose).\(provider.rawValue)"
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load(for purpose: String, provider: ProviderKind) throws -> ProviderCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(purpose).\(provider.rawValue)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return try JSONDecoder().decode(ProviderCredentials.self, from: data)
    }
}

public enum KeychainError: LocalizedError {
    case status(OSStatus)
    public var errorDescription: String? {
        switch self { case .status(let value): "Keychain operation failed (\(value))." }
    }
}

