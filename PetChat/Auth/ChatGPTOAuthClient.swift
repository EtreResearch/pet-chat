import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

protocol OAuthCallbackSession: Sendable {
    func start() throws -> URL
    func receive(authorizationURL: URL) async throws -> URL
}

actor ChatGPTOAuthClient {
    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private let store: KeychainCredentialStore
    private let session: URLSession
    private let callbackSession: OAuthCallbackSession
    private let noRedirects = NoRedirects()
    private var signInInProgress = false
    private var signOutInProgress = false
    private var signInTask: Task<ChatGPTCredential, Error>?
    private var authorizationVersion = UUID()
    private var isShuttingDown = false
    // shortcut: refreshes serialize within this app process; use an interprocess lock if multiple instances share Keychain.
    private var refreshTasks: [String: Task<ChatGPTCredential, Error>] = [:]

    init(store: KeychainCredentialStore = KeychainCredentialStore(), session: URLSession = .shared,
         callbackSession: OAuthCallbackSession = LoopbackOAuthCallbackSession()) {
        self.store = store
        self.session = session
        self.callbackSession = callbackSession
    }

    func signIn() async throws -> ChatGPTCredential {
        let accountID = try store.activeAccountID()
        return try await beginSignIn(existing: accountID.flatMap { try store.load(accountID: $0) })
    }

    private func beginSignIn(existing: ChatGPTCredential?) async throws -> ChatGPTCredential {
        guard !isShuttingDown, !signInInProgress, !signOutInProgress else { throw ChatGPTError.signInFailed }
        signInInProgress = true
        let version = authorizationVersion
        let task = Task { try await authorize(existing: existing, version: version) }
        signInTask = task
        defer { signInInProgress = false; signInTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func signOut() async throws {
        guard !signOutInProgress else { return }
        signOutInProgress = true
        defer { signOutInProgress = false }
        cancelAuthentication()
        guard let accountID = try store.activeAccountID(), let current = try store.load(accountID: accountID) else { return }
        try store.retainRegistration(current)
        var confirmed = false
        do { try await revoke(current); confirmed = true } catch {}
        try store.delete(accountID: accountID)
        if !confirmed { throw ChatGPTError.revocationUnconfirmed }
    }

    func shutdown() {
        isShuttingDown = true
        cancelAuthentication()
    }

    private func cancelAuthentication() {
        authorizationVersion = UUID()
        signInTask?.cancel()
        for task in refreshTasks.values { task.cancel() }
    }

    private func authorize(existing: ChatGPTCredential?, version: UUID) async throws -> ChatGPTCredential {
        try Task.checkCancellation()
        let redirectURI = try callbackSession.start()
        guard redirectURI.scheme == "http", redirectURI.host == "127.0.0.1", redirectURI.path == "/auth/callback",
              redirectURI.port != nil, redirectURI.user == nil, redirectURI.password == nil,
              redirectURI.query == nil, redirectURI.fragment == nil else { throw ChatGPTError.signInFailed }
        let hostID = try store.hostID()
        let registration = try existing == nil ? store.signedOutRegistration() : nil
        guard registration == nil || registration?.hostID == hostID else { throw ChatGPTError.invalidIdentity }
        let registeredClientID = try existing?.clientID ?? registration?.clientID ?? store.pendingClientID()
        let state = try Self.randomURLString()
        let nonce = try Self.randomURLString()
        let verifier = try Self.randomURLString(byteCount: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).urlBase64
        var items = [
            URLQueryItem(name: "client_id", value: registeredClientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        if let existing {
            items.append(URLQueryItem(name: "id_token_hint", value: existing.idToken))
            if let email = existing.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
        } else if registeredClientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: "Pet Chat"))
        }
        var authorization = URLComponents(string: Self.issuer + "/api/accounts/authorize")!
        authorization.queryItems = items
        guard let authorizationURL = authorization.url else { throw ChatGPTError.signInFailed }
        let callback = try await callbackSession.receive(authorizationURL: authorizationURL)
        guard callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.port == redirectURI.port, callback.path == redirectURI.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ChatGPTError.signInFailed
        }
        func one(_ name: String) -> String? {
            let values = query.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard one("state") == state, !query.contains(where: { $0.name == "error" }),
              query.filter({ $0.name == "client_id" }).count <= 1,
              let code = one("code"), !code.isEmpty else { throw ChatGPTError.signInFailed }
        let clientID: String
        if let registeredClientID {
            guard one("client_id") == nil || one("client_id") == registeredClientID else { throw ChatGPTError.signInFailed }
            clientID = registeredClientID
        } else {
            guard let issued = one("client_id"), issued.hasPrefix("oaiapp_"), issued != "dynamic_agent_client" else {
                throw ChatGPTError.signInFailed
            }
            clientID = issued
        }
        try Task.checkCancellation()
        guard authorizationVersion == version, !isShuttingDown else { throw CancellationError() }
        if existing == nil { try store.savePendingClientID(clientID) }
        let tokens = try await exchange([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI.absoluteString, "resource": Self.resource
        ])
        let identity = try await verify(tokens.idToken, clientID: clientID, nonce: nonce)
        let expectedSubject = existing?.subject ?? registration?.subject
        guard expectedSubject == nil || identity.subject == expectedSubject else {
            throw ChatGPTError.invalidIdentity
        }
        let credential = try makeCredential(tokens: tokens, identity: identity, clientID: clientID, hostID: hostID)
        try Task.checkCancellation()
        guard authorizationVersion == version, !isShuttingDown else { throw CancellationError() }
        try store.save(credential, accountID: credential.accountID)
        try store.select(accountID: credential.accountID)
        try store.savePendingClientID(nil)
        return credential
    }

    func credential() async throws -> ChatGPTCredential {
        guard !isShuttingDown, !signOutInProgress else { throw CancellationError() }
        guard let accountID = try store.activeAccountID(), let current = try store.load(accountID: accountID) else {
            throw ChatGPTError.noAccount
        }
        guard current.expiresAt.timeIntervalSinceNow < 60 else { return current }
        if let pending = refreshTasks[accountID] { return try await pending.value }
        let task = Task { try await refresh(current, accountID: accountID) }
        refreshTasks[accountID] = task
        defer { refreshTasks.removeValue(forKey: accountID) }
        return try await task.value
    }

    private func refresh(_ current: ChatGPTCredential, accountID: String) async throws -> ChatGPTCredential {
        let tokens = try await exchange([
            "grant_type": "refresh_token", "client_id": current.clientID,
            "refresh_token": current.refreshToken, "resource": Self.resource
        ])
        let identity = try await verify(tokens.idToken, clientID: current.clientID, nonce: nil)
        guard identity.subject == current.subject else { throw ChatGPTError.invalidIdentity }
        let renewed = try makeCredential(tokens: tokens, identity: identity, clientID: current.clientID, hostID: current.hostID)
        try Task.checkCancellation()
        try store.replace(renewed, ifCurrent: current, accountID: accountID)
        return renewed
    }

    private func makeCredential(tokens: OAuthTokens, identity: Identity, clientID: String, hostID: String) throws -> ChatGPTCredential {
        guard tokens.tokenType == "Bearer", !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
              tokens.expiresIn > 0, tokens.scopes.contains("chatgpt.tokens.use.direct") else {
            throw ChatGPTError.missingPermission
        }
        return ChatGPTCredential(subject: identity.subject, clientID: clientID, hostID: hostID,
                                 email: identity.email, idToken: tokens.idToken,
                                 accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                 scopes: Set(tokens.scopes), expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn)))
    }

    private func exchange(_ fields: [String: String]) async throws -> OAuthTokens {
        let request = Self.formRequest(url: URL(string: Self.issuer + "/api/accounts/oauth/token")!, fields: fields)
        let data = try await load(request, limit: 1_000_000)
        guard let response = try? JSONDecoder().decode(OAuthTokens.self, from: data) else { throw ChatGPTError.signInFailed }
        return response
    }

    private static func formRequest(url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }

    private func revoke(_ credential: ChatGPTCredential) async throws {
        for attempt in 0..<2 {
            do {
                var discovery = URLRequest(url: URL(string: Self.issuer + "/.well-known/openid-configuration")!)
                discovery.timeoutInterval = 5
                let data = try await load(discovery, limit: 1_000_000)
                let configuration = try JSONDecoder().decode(OIDCConfiguration.self, from: data)
                guard configuration.issuer == Self.issuer,
                      configuration.revocationEndpoint.path == "/api/accounts/oauth/revoke" else { throw ChatGPTError.invalidIdentity }
                var request = Self.formRequest(url: configuration.revocationEndpoint, fields: [
                    "token": credential.refreshToken, "token_type_hint": "refresh_token", "client_id": credential.clientID
                ])
                request.timeoutInterval = 5
                guard try await load(request, limit: 1_000_000).isEmpty else { throw ChatGPTError.invalidResponse }
                return
            } catch {
                let retryable: Bool
                if case ChatGPTError.requestFailed(let code) = error { retryable = (500..<600).contains(code) }
                else { retryable = error is URLError && !Task.isCancelled }
                guard attempt == 0, retryable else { throw error }
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func verify(_ token: String, clientID: String, nonce: String?) async throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count < 32_768,
              let headerData = Data(urlBase64: String(parts[0])),
              let payloadData = Data(urlBase64: String(parts[1])),
              let signature = Data(urlBase64: String(parts[2])),
              let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData),
              header.typ == nil || header.typ == "JWT",
              ["RS256", "ES256"].contains(header.alg), !header.kid.isEmpty else {
            throw ChatGPTError.invalidIdentity
        }
        let jwks = try await load(URLRequest(url: URL(string: Self.issuer + "/.well-known/jwks.json")!), limit: 1_000_000)
        guard let keys = try? JSONDecoder().decode(JWKS.self, from: jwks).keys,
              keys.filter({ $0.kid == header.kid }).count == 1,
              let key = keys.first(where: { $0.kid == header.kid }),
              key.alg == nil || key.alg == header.alg,
              key.use == nil || key.use == "sig" else { throw ChatGPTError.invalidIdentity }
        let message = Data("\(parts[0]).\(parts[1])".utf8)
        let valid: Bool
        if header.alg == "ES256", key.kty == "EC", key.crv == "P-256",
           let x = key.x.flatMap(Data.init(urlBase64:)), let y = key.y.flatMap(Data.init(urlBase64:)),
           x.count == 32, y.count == 32,
           let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
           let signed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            valid = publicKey.isValidSignature(signed, for: message)
        } else if header.alg == "RS256", key.kty == "RSA",
                  let n = key.n.flatMap(Data.init(urlBase64:)), let e = key.e.flatMap(Data.init(urlBase64:)),
                  n.count >= 256, n.count <= 512, e.count > 0, e.count <= 4,
                  let rsa = Self.rsaPublicKey(modulus: n, exponent: e) {
            valid = SecKeyVerifySignature(rsa, .rsaSignatureMessagePKCS1v15SHA256,
                                          message as CFData, signature as CFData, nil)
        } else { valid = false }
        guard valid, let claims = try? JSONDecoder().decode(JWTClaims.self, from: payloadData),
              claims.iss == Self.issuer, claims.aud.contains(clientID),
              claims.aud.count == 1 || claims.azp == clientID,
              claims.azp == nil || claims.azp == clientID,
              !claims.sub.isEmpty, claims.exp > Date().timeIntervalSince1970 - 5,
              claims.iat <= Date().timeIntervalSince1970 + 5,
              claims.exp > claims.iat,
              claims.nbf == nil || claims.nbf! <= Date().timeIntervalSince1970 + 5,
              nonce == nil || claims.nonce == nonce else { throw ChatGPTError.invalidIdentity }
        return Identity(subject: claims.sub, email: claims.email)
    }

    private func load(_ request: URLRequest, limit: Int) async throws -> Data {
        guard request.url?.scheme == "https", request.url?.host == "auth.openai.com", request.url?.port == nil,
              request.url?.user == nil, request.url?.password == nil, request.url?.query == nil, request.url?.fragment == nil,
              ["/api/accounts/oauth/token", "/.well-known/jwks.json", "/.well-known/openid-configuration",
               "/api/accounts/oauth/revoke"].contains(request.url?.path ?? "") else {
            throw ChatGPTError.signInFailed
        }
        let (data, response) = try await session.data(for: request, delegate: noRedirects)
        guard let response = response as? HTTPURLResponse, response.url == request.url,
              data.count <= limit else { throw ChatGPTError.signInFailed }
        guard response.statusCode == 200 else { throw ChatGPTError.requestFailed(response.statusCode) }
        return data
    }

    private static func randomURLString(byteCount: Int = 32) throws -> String {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ChatGPTError.signInFailed }
        return bytes.urlBase64
    }

    private static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func length(_ n: Int) -> Data {
            if n < 128 { return Data([UInt8(n)]) }
            let bytes = withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0).drop { $0 == 0 } }
            return Data([0x80 | UInt8(bytes.count)]) + bytes
        }
        func integer(_ value: Data) -> Data {
            let value = value.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + value : value
            return Data([0x02]) + length(value.count) + value
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        return SecKeyCreateWithData(der as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
             kSecAttrKeySizeInBits: modulus.count * 8] as CFDictionary, nil)
    }
}

private struct OIDCConfiguration: Decodable {
    let issuer: String
    let revocationEndpoint: URL
    enum CodingKeys: String, CodingKey { case issuer, revocationEndpoint = "revocation_endpoint" }
}

private struct OAuthTokens: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let tokenType: String
    let expiresIn: Int
    let scopes: [String]
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        idToken = try c.decode(String.self, forKey: .idToken)
        tokenType = try c.decode(String.self, forKey: .tokenType)
        expiresIn = try c.decode(Int.self, forKey: .expiresIn)
        scopes = try c.decode(String.self, forKey: .scope).split(separator: " ").map(String.init)
    }
}

private struct JWTHeader: Decodable { let alg: String; let kid: String; let typ: String? }
private struct JWKS: Decodable { let keys: [JWK] }
private struct JWK: Decodable {
    let kid: String; let kty: String; let alg: String?; let use: String?
    let crv: String?; let x: String?; let y: String?; let n: String?; let e: String?
}
private struct JWTClaims: Decodable {
    let iss: String; let aud: [String]; let azp: String?; let sub: String
    let exp: TimeInterval; let iat: TimeInterval; let nbf: TimeInterval?
    let nonce: String?; let email: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iss = try c.decode(String.self, forKey: .iss)
        if let single = try? c.decode(String.self, forKey: .aud) { aud = [single] }
        else { aud = try c.decode([String].self, forKey: .aud) }
        azp = try c.decodeIfPresent(String.self, forKey: .azp)
        sub = try c.decode(String.self, forKey: .sub)
        exp = try c.decode(TimeInterval.self, forKey: .exp)
        iat = try c.decode(TimeInterval.self, forKey: .iat)
        nbf = try c.decodeIfPresent(TimeInterval.self, forKey: .nbf)
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        email = try c.decodeIfPresent(String.self, forKey: .email)
    }
    enum CodingKeys: String, CodingKey { case iss, aud, azp, sub, exp, iat, nbf, nonce, email }
}
private struct Identity { let subject: String; let email: String? }

extension Data {
    var urlBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(urlBase64: String) {
        guard urlBase64.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let standard = urlBase64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }
}
