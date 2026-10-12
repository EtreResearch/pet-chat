import AppKit
import Darwin
import Foundation

final class LoopbackOAuthCallbackSession: OAuthCallbackSession, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var redirectURI: URL?

    func start() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChatGPTError.signInFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw ChatGPTError.signInFailed
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0,
              let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/auth/callback") else {
            close(fd)
            throw ChatGPTError.signInFailed
        }
        lock.withLock {
            if listener >= 0 { close(listener) }
            listener = fd
            redirectURI = url
        }
        return url
    }

    func receive(authorizationURL: URL) async throws -> URL {
        guard authorizationURL.scheme == "https", authorizationURL.host == "auth.openai.com",
              authorizationURL.path == "/api/accounts/authorize", authorizationURL.port == nil,
              await MainActor.run(body: { NSWorkspace.shared.open(authorizationURL) }) else {
            closeListener()
            throw ChatGPTError.signInFailed
        }
        return try await withTaskCancellationHandler {
            defer { closeListener() }
            return try await Task.detached { [self] in try acceptCallback() }.value
        } onCancel: {
            closeListener()
        }
    }

    private func acceptCallback() throws -> URL {
        let fd = lock.withLock { listener }
        guard fd >= 0, let redirectURI = lock.withLock({ self.redirectURI }) else { throw ChatGPTError.signInFailed }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 300_000) > 0, descriptor.revents & Int16(POLLIN) != 0 else {
            throw ChatGPTError.signInFailed
        }
        let peer = accept(fd, nil, nil)
        guard peer >= 0 else { throw ChatGPTError.signInFailed }
        defer { close(peer) }
        var request = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while request.count <= 8_192 {
            let count = recv(peer, &bytes, bytes.count, 0)
            guard count > 0 else { throw ChatGPTError.signInFailed }
            request.append(contentsOf: bytes[..<count])
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard request.count <= 8_192, let text = String(data: request, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first,
              first.hasPrefix("GET /auth/callback?"), first.hasSuffix(" HTTP/1.1"),
              let target = first.split(separator: " ").dropFirst().first,
              let callback = URL(string: "http://127.0.0.1:\(redirectURI.port!)\(target)") else {
            throw ChatGPTError.signInFailed
        }
        let message = "You can return to Pet Chat. This tab may be closed."
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n\(message)".utf8)
        _ = reply.withUnsafeBytes { send(peer, $0.baseAddress, reply.count, 0) }
        return callback
    }

    private func closeListener() {
        lock.withLock {
            if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
            redirectURI = nil
        }
    }
}
