import Foundation

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw IPCError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw IPCError.io(String(cString: strerror(errno)))
                }
                sent += result
            }
        }
    }
}

/// Listens on a Unix domain socket; each line is one JSON request and gets one JSON reply line.
/// The socket file is readable only by the current user.
public final class IPCServer: @unchecked Sendable {
    /// A request line longer than this closes the connection.
    public static let maxLineBytes = 16 * 1024 * 1024
    public let socketPath: String
    private let handler: @Sendable (IPCRequest) async -> IPCReply
    private let queue = DispatchQueue(label: "IPCServer")
    private var source: DispatchSourceRead?

    public init(socketPath: String, handler: @escaping @Sendable (IPCRequest) async -> IPCReply) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        var address = try UnixSocket.address(socketPath)
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io(String(cString: strerror(errno))) }
        // Create the socket file readable by this user only, with no window before chmod.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw IPCError.io(message)
        }
        chmod(socketPath, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                self?.serve(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(socketPath)
    }

    deinit { stop() }

    private func serve(_ client: Int32) {
        UnixSocket.noSigPipe(client)
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let reader = DispatchSource.makeReadSource(fileDescriptor: client, queue: DispatchQueue(label: "IPCServer.client"))
        var buffer = Data()
        var scanned = 0
        reader.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(client, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else {
                reader.cancel()
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            // Only look at bytes not searched before, so a long line costs linear time.
            while let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                scanned = 0
                if !line.isEmpty { continuation.yield(line) }
            }
            scanned = buffer.count
            if buffer.count > IPCServer.maxLineBytes {
                reader.cancel()
            }
        }
        reader.setCancelHandler { continuation.finish() }
        reader.resume()

        let handler = self.handler
        Task {
            for await line in lines {
                let reply: IPCReply
                if let request = try? JSONDecoder().decode(IPCRequest.self, from: line) {
                    reply = await handler(request)
                } else {
                    reply = IPCReply(ok: false, error: "Invalid request")
                }
                var data = (try? JSONEncoder().encode(reply)) ?? Data(#"{"ok":false}"#.utf8)
                data.append(UInt8(ascii: "\n"))
                try? UnixSocket.writeAll(client, data)
            }
            close(client)
        }
    }
}

public enum IPCClient {
    /// Sends one request and waits for its reply.
    public static func send(_ request: IPCRequest, socketPath: String, timeout: TimeInterval = 10) throws -> IPCReply {
        var data = try JSONEncoder().encode(request)
        data.append(UInt8(ascii: "\n"))
        guard let reply = try exchange(raw: data, socketPath: socketPath, replies: 1, timeout: timeout).first else {
            throw IPCError.invalidReply
        }
        return reply
    }

    /// Writes raw bytes and reads `replies` reply lines (tests use this for framing checks).
    static func exchange(raw: Data, socketPath: String, replies: Int, timeout: TimeInterval = 10) throws -> [IPCReply] {
        var address = try UnixSocket.address(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        UnixSocket.noSigPipe(fd)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw IPCError.appNotRunning }
            throw IPCError.io(String(cString: strerror(errno)))
        }
        try UnixSocket.writeAll(fd, raw)

        var buffer = Data()
        var results: [IPCReply] = []
        let deadline = Date().addingTimeInterval(timeout)
        while results.count < replies {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard remaining > 0, poll(&poller, 1, remaining) > 0 else { throw IPCError.timedOut }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw IPCError.invalidReply }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let reply = try? JSONDecoder().decode(IPCReply.self, from: line) else { throw IPCError.invalidReply }
                results.append(reply)
            }
        }
        return results
    }
}
