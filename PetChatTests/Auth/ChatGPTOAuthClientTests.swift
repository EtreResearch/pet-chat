import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import PetChat

final class ChatGPTOAuthClientTests: XCTestCase {
    override func tearDown() {
        FakeOAuthURLProtocol.handler = nil
        super.tearDown()
    }

    func testDynamicRegistrationBindsStateNoncePKCEAndPersistsIssuedClient() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.client.signIn()
        XCTAssertEqual(result.subject, "person-one")
        XCTAssertEqual(result.clientID, "oaiapp_pet")
        XCTAssertTrue(try fixture.store.load(accountID: result.accountID) == result)
        XCTAssertEqual(try fixture.store.activeAccountID(), result.accountID)
        XCTAssertEqual(result.hostID, try fixture.store.hostID())
        XCTAssertTrue(fixture.authorizeWasChecked)
        XCTAssertTrue(fixture.exchangeWasChecked)
    }

    func testFailedExchangeReusesRegistrationAfterClientRestart() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        fixture.failExchange = true
        do { _ = try await fixture.client.signIn(); XCTFail("Expected exchange failure") } catch {}
        XCTAssertNil(try fixture.store.activeAccountID())
        fixture.expectedClientID = "oaiapp_pet"
        fixture.failExchange = false
        let result = try await fixture.makeClient().signIn()
        XCTAssertEqual(result.clientID, "oaiapp_pet")
    }

    func testSignOutRevokesBeforeDeletingOnlyActiveAppTokens() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        let current = fixture.oldCredential
        let other = ChatGPTCredential(subject: "other", clientID: "oaiapp_other", hostID: current.hostID,
            email: nil, idToken: "other-id", accessToken: "other-access", refreshToken: "other-refresh",
            scopes: current.scopes, expiresAt: .distantFuture)
        try fixture.store.save(current, accountID: current.accountID)
        try fixture.store.save(other, accountID: other.accountID)
        try fixture.store.select(accountID: current.accountID)
        try await fixture.client.signOut()
        XCTAssertNil(try fixture.store.load(accountID: current.accountID))
        XCTAssertNil(try fixture.store.activeAccountID())
        XCTAssertEqual(try fixture.store.load(accountID: other.accountID), other)
        XCTAssertEqual(try fixture.store.hostID(), current.hostID)
        XCTAssertFalse(fixture.authorizeWasChecked)
        XCTAssertFalse(fixture.exchangeWasChecked)
        XCTAssertEqual(fixture.refreshRequestCount, 0)
        XCTAssertEqual(fixture.revocationRequests, 1)
    }

    func testSignOutRetainsRegistrationForRestartWithoutTokenHints() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        let current = fixture.oldCredential
        try fixture.store.save(current, accountID: current.accountID)
        try fixture.store.select(accountID: current.accountID)
        try await fixture.client.signOut()
        fixture.expectedClientID = "oaiapp_pet"
        let restored = try await fixture.makeClient().signIn()
        XCTAssertEqual(restored.subject, current.subject)
        XCTAssertEqual(restored.clientID, current.clientID)
    }

    func testFailedRevocationWarnsButClearsLocalTokens() async throws {
        for statuses in [[503, 503], [400], [0, 0]] {
            let fixture = OAuthFixture()
            defer { fixture.cleanup() }
            fixture.revocationStatuses = statuses
            let current = fixture.oldCredential
            try fixture.store.save(current, accountID: current.accountID)
            try fixture.store.select(accountID: current.accountID)
            do { try await fixture.client.signOut(); XCTFail("Expected unconfirmed revocation warning") }
            catch {
                XCTAssertTrue(error.localizedDescription.contains("remote revocation"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-old-refresh"))
            }
            XCTAssertEqual(fixture.revocationRequests, statuses.count)
            XCTAssertNil(try fixture.store.activeAccountID())
            XCTAssertNil(try fixture.store.load(accountID: current.accountID))
        }
    }

    func testTransientRevocationFailureRetriesThenSignsOutWithoutWarning() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        fixture.revocationStatuses = [503, 200]
        let current = fixture.oldCredential
        try fixture.store.save(current, accountID: current.accountID)
        try fixture.store.select(accountID: current.accountID)
        try await fixture.client.signOut()
        XCTAssertEqual(fixture.revocationRequests, 2)
        XCTAssertNil(try fixture.store.load(accountID: current.accountID))
    }

    func testRevocationDiscoveryCannotSendTokenToUnexpectedEndpoint() async throws {
        for endpoint in ["https://other.example/revoke", "http://auth.openai.com/api/accounts/oauth/revoke",
                         "https://auth.openai.com/api/accounts/oauth/token",
                         "https://auth.openai.com/api/accounts/oauth/revoke?redirect=elsewhere"] {
            let fixture = OAuthFixture()
            defer { fixture.cleanup() }
            fixture.revocationEndpoint = endpoint
            let current = fixture.oldCredential
            try fixture.store.save(current, accountID: current.accountID)
            try fixture.store.select(accountID: current.accountID)
            do { try await fixture.client.signOut(); XCTFail("Expected revocation warning") } catch {}
            XCTAssertEqual(fixture.revocationRequests, 0)
            XCTAssertNil(try fixture.store.load(accountID: current.accountID))
        }
    }

    func testSignedOutRegistrationStillRequiresOriginalSubject() async throws {
        let fixture = OAuthFixture(rejection: .subject)
        defer { fixture.cleanup() }
        let current = fixture.oldCredential
        try fixture.store.save(current, accountID: current.accountID)
        try fixture.store.select(accountID: current.accountID)
        try await fixture.client.signOut()
        fixture.expectedClientID = "oaiapp_pet"
        do { _ = try await fixture.makeClient().signIn(); XCTFail("Expected account mismatch rejection") } catch {}
        XCTAssertNil(try fixture.store.activeAccountID())
        XCTAssertNil(try fixture.store.load(accountID: "oaiapp_pet:person-two"))
    }

    func testSignOutAndShutdownCannotRestorePendingSignIn() async throws {
        for shutdown in [false, true] {
            let fixture = OAuthFixture()
            defer { fixture.cleanup() }
            fixture.signInStarted = expectation(description: "sign-in exchange started")
            fixture.signInDelay = true
            let client = fixture.client
            let pending = Task { try? await client.signIn() }
            await fulfillment(of: [fixture.signInStarted!], timeout: 2)
            if shutdown { await client.shutdown() } else { try await client.signOut() }
            _ = await pending.value
            XCTAssertNil(try fixture.store.activeAccountID())
            XCTAssertNil(try fixture.store.load(accountID: "oaiapp_pet:person-one"))
        }
    }

    func testShutdownPreservesExistingCredentialAndRejectsNewSignIn() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        let current = fixture.oldCredential
        try fixture.store.save(current, accountID: current.accountID)
        try fixture.store.select(accountID: current.accountID)
        await fixture.client.shutdown()
        do { _ = try await fixture.client.signIn(); XCTFail("Shutdown must reject sign-in") } catch {}
        XCTAssertEqual(try fixture.store.load(accountID: current.accountID), current)
        XCTAssertEqual(try fixture.store.activeAccountID(), current.accountID)
        XCTAssertFalse(fixture.authorizeWasChecked)
    }

    func testRS256PublishedJWKVerifiesSyntheticIDToken() async throws {
        let fixture = OAuthFixture(rsa: true)
        defer { fixture.cleanup() }
        let result = try await fixture.client.signIn()
        XCTAssertEqual(result.subject, "person-one")
        XCTAssertTrue(try fixture.store.load(accountID: result.accountID) == result)
    }

    func testOverlappingSignInsCannotReplacePendingCallback() async throws {
        let receiver = HoldingCallbackSession()
        let client = ChatGPTOAuthClient(store: KeychainCredentialStore(service: "com.etre.pet-chat.pending-tests.\(UUID())"),
                                       callbackSession: receiver)
        let first = Task { try await client.signIn() }
        await fulfillment(of: [receiver.entered], timeout: 2)
        do { _ = try await client.signIn(); XCTFail("Expected overlapping attempt rejection") } catch {}
        receiver.release()
        _ = try? await first.value
        XCTAssertEqual(receiver.startCount, 1)
    }

    func testRejectedCallbacksAndIDTokensLeaveExistingCredentialUntouched() async throws {
        for rejection in OAuthFixture.Rejection.allCases where rejection != .refreshSubject {
            let fixture = OAuthFixture(rejection: rejection)
            defer { fixture.cleanup() }
            let old = fixture.oldCredential
            try fixture.store.save(old, accountID: old.accountID)
            try fixture.store.select(accountID: old.accountID)
            do {
                _ = try await fixture.client.signIn()
                XCTFail("Expected rejection: \(rejection)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            }
            XCTAssertTrue(try fixture.store.load(accountID: old.accountID) == old, "\(rejection)")
            XCTAssertEqual(try fixture.store.activeAccountID(), old.accountID, "\(rejection)")
        }
    }

    func testRefreshRotatesBothTokensAndPreservesOldOnFailure() async throws {
        let fixture = OAuthFixture()
        defer { fixture.cleanup() }
        let old = fixture.oldCredential
        try fixture.store.save(old, accountID: old.accountID)
        try fixture.store.select(accountID: old.accountID)
        let refreshed = try await fixture.client.credential()
        XCTAssertTrue(refreshed.accessToken == "synthetic-new-access")
        XCTAssertTrue(refreshed.refreshToken == "synthetic-new-refresh")
        XCTAssertTrue(try fixture.store.load(accountID: old.accountID) == refreshed)

        for rejection in [OAuthFixture.Rejection.refreshScope, .refreshSubject] {
            let failed = OAuthFixture(rejection: rejection)
            defer { failed.cleanup() }
            try failed.store.save(old, accountID: old.accountID)
            try failed.store.select(accountID: old.accountID)
            do { _ = try await failed.client.credential(); XCTFail("Expected refresh rejection") } catch {}
            XCTAssertTrue(try failed.store.load(accountID: old.accountID) == old)
        }
    }

    func testConcurrentCallersShareOneRotatingRefresh() async throws {
        let fixture = OAuthFixture(refreshDelay: true)
        defer { fixture.cleanup() }
        let old = fixture.oldCredential
        try fixture.store.save(old, accountID: old.accountID)
        try fixture.store.select(accountID: old.accountID)
        let client = fixture.client
        async let first = client.credential()
        async let second = client.credential()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.accountID, b.accountID)
        XCTAssertTrue(a.accessToken == b.accessToken && a.refreshToken == b.refreshToken && a.idToken == b.idToken)
        XCTAssertEqual(fixture.refreshRequestCount, 1)
    }

    func testRefreshCannotOverwriteReauthorizedCredential() async throws {
        let fixture = OAuthFixture(refreshDelay: true)
        defer { fixture.cleanup() }
        let old = fixture.oldCredential
        try fixture.store.save(old, accountID: old.accountID)
        try fixture.store.select(accountID: old.accountID)
        let started = expectation(description: "refresh request started")
        fixture.refreshStarted = started
        let client = fixture.client
        let pending = Task { try? await client.credential() }
        await fulfillment(of: [started], timeout: 2)

        let replacement = ChatGPTCredential(subject: old.subject, clientID: old.clientID, hostID: old.hostID,
            email: old.email, idToken: "replacement-id", accessToken: "replacement-access",
            refreshToken: "replacement-refresh", scopes: old.scopes,
            expiresAt: Date().addingTimeInterval(3600))
        try fixture.store.save(replacement, accountID: old.accountID)
        _ = await pending.value
        XCTAssertTrue(try fixture.store.load(accountID: old.accountID) == replacement)
    }

    func testRefreshCannotResurrectDeletedCredential() async throws {
        let fixture = OAuthFixture(refreshDelay: true)
        defer { fixture.cleanup() }
        let old = fixture.oldCredential
        try fixture.store.save(old, accountID: old.accountID)
        try fixture.store.select(accountID: old.accountID)
        let started = expectation(description: "refresh request started")
        fixture.refreshStarted = started
        let client = fixture.client
        let pending = Task { try? await client.credential() }
        await fulfillment(of: [started], timeout: 2)

        try fixture.store.delete(accountID: old.accountID)
        _ = await pending.value
        XCTAssertNil(try fixture.store.load(accountID: old.accountID))
        XCTAssertNil(try fixture.store.activeAccountID())
    }

    func testCancelledLoopbackCallbackStopsReadingIncompletePeer() async throws {
        let callback = LoopbackOAuthCallbackSession(openBrowser: { _ in true })
        let redirect = try callback.start()
        let finished = expectation(description: "cancelled callback completed")
        let pending = Task {
            _ = try? await callback.receive(authorizationURL: URL(string: "https://auth.openai.com/api/accounts/authorize")!)
            finished.fulfill()
        }
        let peer = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer); pending.cancel() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(redirect.port!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(peer, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let incomplete = Data("GET /auth/callback?code=x HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
        XCTAssertEqual(incomplete.withUnsafeBytes { send(peer, $0.baseAddress, incomplete.count, 0) }, incomplete.count)
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testIncompleteLoopbackHeadersExpireWithoutPeerDisconnecting() async throws {
        let callback = LoopbackOAuthCallbackSession(headerReadTimeout: 0.2, openBrowser: { _ in true })
        let redirect = try callback.start()
        let finished = expectation(description: "incomplete callback expired")
        let pending = Task {
            _ = try? await callback.receive(authorizationURL: URL(string: "https://auth.openai.com/api/accounts/authorize")!)
            finished.fulfill()
        }
        let peer = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer); pending.cancel() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(redirect.port!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(peer, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let incomplete = Data("GET /auth/callback?code=x HTTP/1.1\r\n".utf8)
        XCTAssertEqual(incomplete.withUnsafeBytes { send(peer, $0.baseAddress, incomplete.count, 0) }, incomplete.count)
        await fulfillment(of: [finished], timeout: 2)
    }
}

private final class OAuthFixture: @unchecked Sendable {
    enum Rejection: String, CaseIterable {
        case state, nonce, expired, audience, authorizedParty, issuer, signature, unknownKid, scope, subject
        case callbackClient, callbackURI, callbackDuplicateClient, callbackError, tokenRedirect, jwksRedirect
        case refreshScope, refreshSubject
    }

    let service = "com.etre.pet-chat.oauth-tests.\(UUID())"
    lazy var store = KeychainCredentialStore(service: service)
    let key = P256.Signing.PrivateKey()
    let rsaKey: SecKey?
    let rejection: Rejection?
    let refreshDelay: Bool
    var signInStarted: XCTestExpectation?
    var signInDelay = false
    var refreshStarted: XCTestExpectation?
    private let refreshLock = NSLock()
    private var refreshRequests = 0
    var refreshRequestCount: Int { refreshLock.withLock { refreshRequests } }
    let issuedClientID = "oaiapp_pet"
    let issuedSubject = "person-one"
    var authorizeWasChecked = false
    var exchangeWasChecked = false
    var failExchange = false
    var expectedClientID: String?
    var revocationRequests = 0
    var revocationStatuses = [200]
    var revocationEndpoint = "https://auth.openai.com/api/accounts/oauth/revoke"
    lazy var oldCredential = ChatGPTCredential(subject: "person-one", clientID: "oaiapp_pet", hostID: try! store.hostID(),
        email: "first@example.test", idToken: "synthetic-old-id", accessToken: "synthetic-old-access",
        refreshToken: "synthetic-old-refresh", scopes: ["chatgpt.tokens.use.direct"], expiresAt: .distantPast)
    lazy var client: ChatGPTOAuthClient = makeClient()
    func makeClient() -> ChatGPTOAuthClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOAuthURLProtocol.self]
        FakeOAuthURLProtocol.handler = { [self] request in try self.respond(to: request) }
        return ChatGPTOAuthClient(store: store, session: URLSession(configuration: config), callbackSession: FakeCallbackSession { [self] url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "auth.openai.com")
            XCTAssertEqual(url.path, "/api/accounts/authorize")
            let active = try store.activeAccountID()
            let firstRegistration = active == nil
            let expected = expectedClientID ?? (firstRegistration ? "dynamic_agent_client" : "oaiapp_pet")
            XCTAssertEqual(value("client_id"), expected)
            XCTAssertEqual(value("agent_name_hint"), expected == "dynamic_agent_client" ? "Pet Chat" : nil)
            if active == nil { XCTAssertNil(value("id_token_hint")); XCTAssertNil(value("login_hint")) }
            XCTAssertEqual(value("ext_agent_host_id"), try store.hostID())
            XCTAssertEqual(value("resource"), "https://api.openai.com/v1")
            XCTAssertEqual(value("scope"), "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
            XCTAssertEqual(value("code_challenge_method"), "S256")
            XCTAssertNotNil(value("code_challenge"))
            XCTAssertNotNil(value("nonce"))
            FakeCallbackSession.lastChallenge = value("code_challenge")
            authorizeWasChecked = true
            var callback = URLComponents(string: rejection == .callbackURI ? "http://localhost:49152/auth/callback" : "http://127.0.0.1:49152/auth/callback")!
            callback.queryItems = [URLQueryItem(name: "code", value: "synthetic-code"),
                                   URLQueryItem(name: "state", value: rejection == .state ? "wrong" : value("state")),
                                   URLQueryItem(name: "client_id", value: rejection == .callbackClient ? "oaiapp_other" : issuedClientID)]
            if rejection == .callbackDuplicateClient { callback.queryItems?.append(URLQueryItem(name: "client_id", value: issuedClientID)) }
            if rejection == .callbackError { callback.queryItems?.append(URLQueryItem(name: "error", value: "access_denied")) }
            return callback.url!
        })
    }

    init(rejection: Rejection? = nil, rsa: Bool = false, refreshDelay: Bool = false) {
        self.rejection = rejection
        self.refreshDelay = refreshDelay
        rsaKey = rsa ? SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                              kSecAttrKeySizeInBits: 2048] as CFDictionary, nil) : nil
    }

    func cleanup() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    private func respond(to request: URLRequest) throws -> (Int, Data) {
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "auth.openai.com")
        if request.url?.path == "/.well-known/openid-configuration" {
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try JSONSerialization.data(withJSONObject: ["issuer": "https://auth.openai.com", "revocation_endpoint": revocationEndpoint]))
        }
        if request.url?.path == "/api/accounts/oauth/revoke" {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let form = URLComponents(string: "?" + String(data: request.testBody, encoding: .utf8)!)!.queryItems!
            XCTAssertEqual(form.first { $0.name == "client_id" }?.value, "oaiapp_pet")
            XCTAssertTrue(form.first { $0.name == "token" }?.value == "synthetic-old-refresh")
            XCTAssertEqual(form.first { $0.name == "token_type_hint" }?.value, "refresh_token")
            XCTAssertNotNil(try store.load(accountID: oldCredential.accountID))
            let status = revocationStatuses[min(revocationRequests, revocationStatuses.count - 1)]
            revocationRequests += 1
            if status == 0 { throw URLError(.notConnectedToInternet) }
            return (status, Data())
        }
        if request.url?.path == "/.well-known/jwks.json" {
            if rejection == .jwksRedirect { return (302, Data()) }
            let jwk: [String: Any]
            if let rsaKey, let publicKey = SecKeyCopyPublicKey(rsaKey),
               let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
               let (n, e) = Self.rsaComponents(bytes) {
                jwk = ["kty": "RSA", "alg": "RS256", "use": "sig", "kid": "fixture", "n": n.urlBase64, "e": e.urlBase64]
            } else {
                let raw = key.publicKey.x963Representation
                jwk = ["kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": "fixture",
                       "x": Data(raw[1..<33]).urlBase64, "y": Data(raw[33..<65]).urlBase64]
            }
            return (200, try JSONSerialization.data(withJSONObject: ["keys": [jwk]]))
        }
        XCTAssertEqual(request.url?.path, "/api/accounts/oauth/token")
        if failExchange { return (503, Data()) }
        if rejection == .tokenRedirect { return (302, Data()) }
        let body = String(data: request.testBody, encoding: .utf8) ?? ""
        let form = URLComponents(string: "?\(body)")!.queryItems ?? []
        func field(_ name: String) -> String? { form.first { $0.name == name }?.value }
        XCTAssertEqual(field("client_id"), issuedClientID)
        XCTAssertEqual(field("resource"), "https://api.openai.com/v1")
        if field("grant_type") == "refresh_token" {
            refreshLock.withLock { refreshRequests += 1 }
            refreshStarted?.fulfill()
            if refreshDelay { Thread.sleep(forTimeInterval: 0.2) }
            XCTAssertTrue(field("refresh_token") == "synthetic-old-refresh")
            XCTAssertNil(field("scope"))
            return (200, try tokenResponse(nonce: nil, refresh: true))
        }
        XCTAssertEqual(field("grant_type"), "authorization_code")
        XCTAssertEqual(field("redirect_uri"), "http://127.0.0.1:49152/auth/callback")
        XCTAssertTrue(field("code") == "synthetic-code")
        XCTAssertNotNil(field("code_verifier"))
        if let verifier = field("code_verifier") {
            XCTAssertEqual(Data(SHA256.hash(data: Data(verifier.utf8))).urlBase64, FakeCallbackSession.lastChallenge)
        }
        signInStarted?.fulfill()
        if signInDelay { Thread.sleep(forTimeInterval: 0.2) }
        exchangeWasChecked = true
        return (200, try tokenResponse(nonce: FakeCallbackSession.lastNonce, refresh: false))
    }

    private func tokenResponse(nonce: String?, refresh: Bool) throws -> Data {
        let header = ["alg": rsaKey == nil ? "ES256" : "RS256", "kid": rejection == .unknownKid ? "other" : "fixture", "typ": "JWT"]
        var claims: [String: Any] = ["iss": rejection == .issuer ? "https://other.example" : "https://auth.openai.com",
                                     "aud": rejection == .audience ? "oaiapp_other" : issuedClientID,
                                     "sub": rejection == .subject || (refresh && rejection == .refreshSubject) ? "person-two" : issuedSubject,
                                     "exp": rejection == .expired ? 1 : Int(Date().timeIntervalSince1970) + 3600,
                                     "iat": Int(Date().timeIntervalSince1970)]
        if let nonce { claims["nonce"] = rejection == .nonce ? "wrong" : nonce }
        if rejection == .authorizedParty { claims["azp"] = "oaiapp_other" }
        let message = try JSONSerialization.data(withJSONObject: header).urlBase64 + "." + JSONSerialization.data(withJSONObject: claims).urlBase64
        let signature: String
        if let rsaKey {
            signature = (SecKeyCreateSignature(rsaKey, .rsaSignatureMessagePKCS1v15SHA256,
                                               Data(message.utf8) as CFData, nil)! as Data).urlBase64
        } else {
            signature = try (rejection == .signature ? P256.Signing.PrivateKey() : key).signature(for: Data(message.utf8)).rawRepresentation.urlBase64
        }
        let token = "\(message).\(signature)"
        let response: [String: Any] = ["access_token": refresh ? "synthetic-new-access" : "synthetic-access",
                                       "refresh_token": refresh ? "synthetic-new-refresh" : "synthetic-refresh",
                                       "id_token": token, "token_type": "Bearer", "expires_in": 3600,
                                       "scope": (rejection == .scope || rejection == .refreshScope) ? "openid profile" : "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private static func rsaComponents(_ der: Data) -> (Data, Data)? {
        let bytes = [UInt8](der)
        var offset = 0
        func read(_ tag: UInt8) -> Data? {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
            offset += 1
            var count = Int(bytes[offset]); offset += 1
            if count & 0x80 != 0 {
                let lengthBytes = count & 0x7f
                guard lengthBytes > 0, lengthBytes <= 4, offset + lengthBytes <= bytes.count else { return nil }
                count = 0
                for byte in bytes[offset..<(offset + lengthBytes)] { count = count * 256 + Int(byte) }
                offset += lengthBytes
            }
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        guard read(0x30) != nil else { return nil }
        offset = der[1] & 0x80 == 0 ? 2 : 2 + Int(der[1] & 0x7f)
        guard let n = read(0x02), let e = read(0x02) else { return nil }
        return (Data(n.drop { $0 == 0 }), Data(e.drop { $0 == 0 }))
    }
}

private final class FakeCallbackSession: OAuthCallbackSession, @unchecked Sendable {
    nonisolated(unsafe) static var lastNonce: String?
    nonisolated(unsafe) static var lastChallenge: String?
    let callback: (URL) throws -> URL
    init(callback: @escaping (URL) throws -> URL) { self.callback = callback }
    func start() throws -> URL { URL(string: "http://127.0.0.1:49152/auth/callback")! }
    func receive(authorizationURL: URL) async throws -> URL {
        Self.lastNonce = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nonce" }?.value
        return try callback(authorizationURL)
    }
}

private final class HoldingCallbackSession: OAuthCallbackSession, @unchecked Sendable {
    let entered = XCTestExpectation(description: "First callback waiting")
    private let lock = NSLock()
    private var starts = 0
    private var waiting: CheckedContinuation<URL, Error>?
    var startCount: Int { lock.withLock { starts } }
    func start() throws -> URL {
        lock.withLock { starts += 1 }
        return URL(string: "http://127.0.0.1:49152/auth/callback")!
    }
    func receive(authorizationURL: URL) async throws -> URL {
        if startCount > 1 { throw ChatGPTError.signInFailed }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting = continuation }
            entered.fulfill()
        }
    }
    func release() {
        let continuation = lock.withLock { let value = waiting; waiting = nil; return value }
        continuation?.resume(throwing: ChatGPTError.signInFailed)
    }
}

private final class FakeOAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private extension Data {
    var urlBase64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private extension URLRequest {
    var testBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return body }
            body.append(contentsOf: buffer[..<count])
        }
    }
}
