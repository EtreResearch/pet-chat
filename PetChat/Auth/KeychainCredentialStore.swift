import Foundation
import Security

final class KeychainCredentialStore: @unchecked Sendable {
    private let service: String

    init(service: String = "com.etre.pet-chat.chatgpt") { self.service = service }

    func load(accountID: String) throws -> ChatGPTCredential? {
        guard let data = try read("credential:\(accountID)") else { return nil }
        guard let credential = try? JSONDecoder().decode(ChatGPTCredential.self, from: data),
              credential.accountID == accountID else { throw ChatGPTError.invalidIdentity }
        return credential
    }

    func save(_ credential: ChatGPTCredential, accountID: String) throws {
        guard credential.accountID == accountID else { throw ChatGPTError.invalidIdentity }
        try write(JSONEncoder().encode(credential), key: "credential:\(accountID)")
    }

    func delete(accountID: String) throws {
        try remove("credential:\(accountID)")
        if try activeAccountID() == accountID { try remove("active-account") }
    }

    func activeAccountID() throws -> String? {
        guard let data = try read("active-account"), let id = String(data: data, encoding: .utf8) else { return nil }
        return id
    }

    func select(accountID: String) throws {
        guard try load(accountID: accountID) != nil else { throw ChatGPTError.noAccount }
        try write(Data(accountID.utf8), key: "active-account")
    }

    func hostID() throws -> String {
        if let data = try read("host-id"), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        try write(Data(id.utf8), key: "host-id")
        return id
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    private func read(_ key: String) throws -> Data? {
        var attributes = query(key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw KeychainError.failure(status) }
        return data
    }

    private func write(_ data: Data, key: String) throws {
        var attributes = query(key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.failure(update) }
        } else if status != errSecSuccess { throw KeychainError.failure(status) }
    }

    private func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.failure(status) }
    }
}

private enum KeychainError: LocalizedError {
    case failure(OSStatus)
    var errorDescription: String? { "Could not access the app's ChatGPT credentials in Keychain." }
}
