import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws
    func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials?
}

public struct KeychainStore: CredentialStoring, Sendable {
    private let service: String
    public init(service: String = "ai.dictator.credentials") { self.service = service }

    public func save(_ credentials: ProviderCredentials, for purpose: ProviderPurpose, provider: ProviderKind) throws {
        let account = "\(purpose.rawValue).\(provider.rawValue)"
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }

        let item = query.merging(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    public func load(for purpose: ProviderPurpose, provider: ProviderKind) throws -> ProviderCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(purpose.rawValue).\(provider.rawValue)",
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

public enum CredentialReuseMigration {
    public static func preserveCleanupCredential(
        previousSTT: ProviderKind,
        selectedCleanup: ProviderKind,
        store: any CredentialStoring
    ) throws {
        guard previousSTT == selectedCleanup,
              try store.load(for: .cleanup, provider: selectedCleanup) == nil,
              let shared = try store.load(for: .speechToText, provider: previousSTT)
        else { return }
        try store.save(shared, for: .cleanup, provider: selectedCleanup)
    }
}

public enum KeychainError: LocalizedError {
    case status(OSStatus)
    public var errorDescription: String? {
        switch self { case .status(let value): "Keychain operation failed (\(value))." }
    }
}
