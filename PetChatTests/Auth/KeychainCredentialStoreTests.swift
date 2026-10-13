import Foundation
import Security
import XCTest
@testable import PetChat

final class KeychainCredentialStoreTests: XCTestCase {
    func testCredentialsAreIsolatedByAccountAndService() throws {
        let service = "com.etre.pet-chat.tests.\(UUID())"
        defer { Self.clear(service); Self.clear("\(service).other") }
        let store = KeychainCredentialStore(service: service)
        let otherStore = KeychainCredentialStore(service: "\(service).other")
        let first = credential(subject: "first", clientID: "oaiapp_one")
        let second = credential(subject: "second", clientID: "oaiapp_two")

        try store.save(first, accountID: first.accountID)
        try store.save(second, accountID: second.accountID)
        try store.select(accountID: first.accountID)
        XCTAssertTrue(try store.load(accountID: first.accountID) == first)
        XCTAssertTrue(try store.load(accountID: second.accountID) == second)
        XCTAssertNil(try otherStore.load(accountID: first.accountID))
        XCTAssertEqual(try store.activeAccountID(), first.accountID)

        try store.delete(accountID: first.accountID)
        XCTAssertNil(try store.activeAccountID())
        XCTAssertTrue(try store.load(accountID: second.accountID) == second)
    }

    func testHostIDPersistsAndCannotBeReplacedByAccountSave() throws {
        let service = "com.etre.pet-chat.tests.\(UUID())"
        defer { Self.clear(service) }
        let store = KeychainCredentialStore(service: service)
        let first = try store.hostID()
        XCTAssertTrue(first.hasPrefix("urn:uuid:"))
        XCTAssertEqual(try store.hostID(), first)
        let credential = credential(subject: "first", clientID: "oaiapp_one")
        try store.save(credential, accountID: credential.accountID)
        XCTAssertEqual(try store.hostID(), first)
        XCTAssertThrowsError(try store.save(credential, accountID: "wrong-account"))
    }

    private func credential(subject: String, clientID: String) -> ChatGPTCredential {
        ChatGPTCredential(subject: subject, clientID: clientID, hostID: "urn:uuid:test", email: nil,
                          idToken: "synthetic-id", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                          scopes: ["chatgpt.tokens.use.direct"], expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    private static func clear(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}
