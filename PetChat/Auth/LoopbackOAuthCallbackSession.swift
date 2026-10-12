import AppKit
import Darwin
import Foundation

final class LoopbackOAuthCallbackSession: OAuthCallbackSession, @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var acceptedPeer: Int32 = -1
    private var redirectURI: URL?
    private var cancelled = false
    private let openBrowser: @Sendable (URL) async -> Bool
    private let headerReadTimeout: TimeInterval

    init(headerReadTimeout: TimeInterval = 10, openBrowser: @escaping @Sendable (URL) async -> Bool = { url in
        await MainActor.run { NSWorkspace.shared.open(url) }
    }) {
        self.headerReadTimeout = headerReadTimeout
        self.openBrowser = openBrowser
    }

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
            cancelled = false
        }
        return url
    }

    func receive(authorizationURL: URL) async throws -> URL {
        guard authorizationURL.scheme == "https", authorizationURL.host == "auth.openai.com",
              authorizationURL.path == "/api/accounts/authorize", authorizationURL.port == nil,
              await openBrowser(authorizationURL) else {
            closeListener()
            throw ChatGPTError.signInFailed
        }
        do { try Task.checkCancellation() } catch {
            closeListener()
            throw error
        }
        return try await withTaskCancellationHandler {
            defer { closeListener() }
            return try await Task.detached { [self] in try acceptCallback() }.value
        } onCancel: {
            closeListener()
        }
    }

    private func acceptCallback() throws -> URL {
        let (fd, redirectURI) = lock.withLock { (listener, self.redirectURI) }
        guard fd >= 0, let redirectURI else { throw ChatGPTError.signInFailed }
        try waitUntilReadable(fd, deadline: DispatchTime.now().uptimeNanoseconds + 300_000_000_000)
        let peer = accept(fd, nil, nil)
        guard peer >= 0 else { throw ChatGPTError.signInFailed }
        let wasCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            acceptedPeer = peer
            return false
        }
        if wasCancelled { close(peer); throw ChatGPTError.signInFailed }
        defer {
            lock.withLock {
                if acceptedPeer == peer { acceptedPeer = -1 }
                close(peer)
            }
        }
        guard fcntl(peer, F_SETFL, O_NONBLOCK) == 0 else { throw ChatGPTError.signInFailed }
        var request = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, headerReadTimeout) * 1_000_000_000)
        while request.count <= 8_192 {
            try waitUntilReadable(peer, deadline: deadline)
            let count = recv(peer, &bytes, bytes.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
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

    private func waitUntilReadable(_ fd: Int32, deadline: UInt64) throws {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if lock.withLock({ cancelled }) { throw ChatGPTError.signInFailed }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 {
                guard descriptor.revents & Int16(POLLIN) != 0 else { throw ChatGPTError.signInFailed }
                if lock.withLock({ cancelled }) { throw ChatGPTError.signInFailed }
                return
            }
            if result < 0 && errno != EINTR { throw ChatGPTError.signInFailed }
        }
        throw ChatGPTError.signInFailed
    }

    private func closeListener() {
        lock.withLock {
            cancelled = true
            if acceptedPeer >= 0 { shutdown(acceptedPeer, SHUT_RDWR) }
            if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
            redirectURI = nil
        }
    }
}
