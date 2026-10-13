import Foundation
import Security

final class KeychainCredentialStore: @unchecked Sendable {
    private static let lock = NSRecursiveLock()
    private let service: String

    init(service: String = "com.etre.pet-chat.chatgpt") { self.service = service }

    func load(accountID: String) throws -> ChatGPTCredential? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try read("credential:\(accountID)") else { return nil }
        guard let credential = try? JSONDecoder().decode(ChatGPTCredential.self, from: data),
              credential.accountID == accountID else { throw ChatGPTError.invalidIdentity }
        return credential
    }

    func save(_ credential: ChatGPTCredential, accountID: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard credential.accountID == accountID else { throw ChatGPTError.invalidIdentity }
        try write(JSONEncoder().encode(credential), key: "credential:\(accountID)")
    }

    func replace(_ credential: ChatGPTCredential, ifCurrent expected: ChatGPTCredential, accountID: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard try activeAccountID() == accountID,
              try load(accountID: accountID) == expected else { throw ChatGPTError.invalidIdentity }
        try save(credential, accountID: accountID)
    }

    func delete(accountID: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try remove("credential:\(accountID)")
        if try activeAccountID() == accountID { try remove("active-account") }
    }

    func activeAccountID() throws -> String? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = try read("active-account"), let id = String(data: data, encoding: .utf8) else { return nil }
        return id
    }

    func select(accountID: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard try load(accountID: accountID) != nil else { throw ChatGPTError.noAccount }
        try write(Data(accountID.utf8), key: "active-account")
    }

    func hostID() throws -> String {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let data = try read("host-id"), let id = String(data: data, encoding: .utf8), !id.isEmpty { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        try write(Data(id.utf8), key: "host-id")
        return id
    }

    func pendingClientID() throws -> String? {
        try Self.lock.withLock {
            try read("pending-client-id").flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    func signedOutRegistration() throws -> ChatGPTRegistration? {
        try Self.lock.withLock {
            guard let data = try read("signed-out-registration") else { return nil }
            return try JSONDecoder().decode(ChatGPTRegistration.self, from: data)
        }
    }

    func retainRegistration(_ credential: ChatGPTCredential) throws {
        try Self.lock.withLock {
            try write(JSONEncoder().encode(ChatGPTRegistration(credential)), key: "signed-out-registration")
        }
    }

    func savePendingClientID(_ id: String?) throws {
        try Self.lock.withLock {
            if let id { try write(Data(id.utf8), key: "pending-client-id") }
            else { try remove("pending-client-id") }
        }
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
