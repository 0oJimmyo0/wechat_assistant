import Foundation
import Darwin

/// One-shot HTTP callback bound only to IPv4 loopback for OAuth.
final class LoopbackCallbackServer: @unchecked Sendable {
    private let socketFD: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        guard listen(fd, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        socketFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)
    }

    deinit { close(socketFD) }

    func receiveCallback(expectedState: String) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let clientFD = accept(self.socketFD, nil, nil)
                guard clientFD >= 0 else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                defer { close(clientFD) }
                var noSignal: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

                var buffer = [UInt8](repeating: 0, count: 16_384)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    recv(clientFD, bytes.baseAddress, bytes.count, 0)
                }
                guard count > 0, let request = String(bytes: buffer.prefix(count), encoding: .utf8),
                      let requestLine = request.components(separatedBy: "\r\n").first,
                      requestLine.hasPrefix("GET "),
                      let path = requestLine.split(separator: " ").dropFirst().first,
                      let components = URLComponents(string: "http://127.0.0.1\(path)"),
                      components.path == "/auth/callback" else {
                    self.sendResponse(clientFD, status: "400 Bad Request", message: "Invalid sign-in callback")
                    continuation.resume(throwing: CopilotError.service("Invalid local sign-in callback."))
                    return
                }
                let values = Dictionary((components.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }, uniquingKeysWith: { _, latest in latest })
                let matchesState = values["state"] == expectedState
                self.sendResponse(clientFD,
                                  status: matchesState ? "200 OK" : "400 Bad Request",
                                  message: matchesState ? "You can return to the app." : "Invalid sign-in callback")
                continuation.resume(returning: values)
            }
        }
    }

    private func sendResponse(_ fd: Int32, status: String, message: String) {
        let body = "<html><head><meta name=\"referrer\" content=\"no-referrer\"></head><body><h2>WeChat Reply Copilot</h2><p>\(message)</p><script>history.replaceState(null, \"\", \"/auth/callback\")</script></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}
