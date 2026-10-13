import Foundation

struct ChatGPTCredential: Codable, Equatable, Sendable {
    let subject: String
    let clientID: String
    let hostID: String
    let email: String?
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let scopes: Set<String>
    let expiresAt: Date

    var accountID: String { "\(clientID):\(subject)" }
}

enum ChatGPTError: LocalizedError {
    case signInFailed, invalidIdentity, missingPermission, noAccount
    case requestFailed(Int)
    case invalidResponse, incompleteResponse, usageLimit, unsupportedImages

    var errorDescription: String? {
        switch self {
        case .signInFailed: "ChatGPT sign-in did not complete. Try again."
        case .invalidIdentity: "ChatGPT could not verify this account. Try signing in again."
        case .missingPermission: "ChatGPT plan access was not granted. Reconnect and allow plan usage."
        case .noAccount: "Connect a ChatGPT account to continue."
        case .requestFailed(let code): "ChatGPT request failed (HTTP \(code)). Try again or reconnect."
        case .invalidResponse: "ChatGPT returned an invalid response. Try again."
        case .incompleteResponse: "ChatGPT stopped before completing the answer. Try again."
        case .usageLimit: "ChatGPT plan usage limit reached. Wait for the limit to reset, then retry."
        case .unsupportedImages: "ChatGPT accepts PNG, JPEG, GIF, or WebP images. Attach a supported image."
        }
    }
}
