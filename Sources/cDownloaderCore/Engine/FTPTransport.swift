import Foundation
import Network

/// Passive-mode FTP downloads. Each connection logs in on its own control channel,
/// uses REST to start at its offset and reads one data channel.
public final class FTPTransport: Transport, @unchecked Sendable {
    public struct Options: Sendable {
        public var timeout: TimeInterval = 30
        public init() {}
    }

    let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func open(_ request: TransferRequest, delegate: TransferConnectionDelegate, queue: DispatchQueue) -> TransferConnection {
        let connection = FTPConnection(request: request, timeout: options.timeout, delegate: delegate, queue: queue)
        connection.start()
        return connection
    }

    public func invalidate() {}
}

final class FTPConnection: TransferConnection, @unchecked Sendable {
    private let request: TransferRequest
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var delegate: TransferConnectionDelegate?
    private var task: Task<Void, Never>?
    private var streams: [NWStream] = []
    private var suspended = false
    private var resumeWaiter: CheckedContinuation<Void, Never>?
    private var cancelled = false

    init(request: TransferRequest, timeout: TimeInterval, delegate: TransferConnectionDelegate, queue: DispatchQueue) {
        self.request = request
        self.timeout = timeout
        self.delegate = delegate
        self.queue = queue
    }

    func start() {
        task = Task { [self] in await run() }
    }

    func cancel() {
        let (open, waiter) = lock.withLock { () -> ([NWStream], CheckedContinuation<Void, Never>?) in
            cancelled = true
            delegate = nil
            let waiter = resumeWaiter
            resumeWaiter = nil
            return (streams, waiter)
        }
        open.forEach { $0.cancel() }
        waiter?.resume()
        task?.cancel()
    }

    func suspend() {
        lock.withLock { suspended = true }
    }

    func resume() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            suspended = false
            let waiter = resumeWaiter
            resumeWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func waitWhileSuspended() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if suspended && !cancelled {
                    resumeWaiter = continuation
                    return false
                }
                return true
            }
            if ready { continuation.resume() }
        }
    }

    private func track(_ stream: NWStream) throws {
        let alreadyCancelled = lock.withLock { () -> Bool in
            streams.append(stream)
            return cancelled
        }
        if alreadyCancelled {
            stream.cancel()
            throw DownloadFailure.cancelled
        }
    }

    // MARK: - Delivery (in order, on the job's queue)

    private func deliver(_ body: @escaping @Sendable (TransferConnectionDelegate, FTPConnection) -> Void) {
        queue.async { [self] in
            guard let delegate = lock.withLock({ delegate }) else { return }
            body(delegate, self)
        }
    }

    private func finish(_ failure: DownloadFailure?) {
        queue.async { [self] in
            let delegate = lock.withLock { () -> TransferConnectionDelegate? in
                let current = delegate
                delegate = nil
                return current
            }
            delegate?.connection(self, didCompleteWith: failure)
        }
    }

    // MARK: - Session

    private func run() async {
        defer { lock.withLock { streams }.forEach { $0.cancel() } }
        do {
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
            let host = components?.host ?? ""
            let port = UInt16(components?.port ?? 21)
            let control = try await NWStream.connect(host: host, port: port, timeout: timeout)
            try track(control)
            let channel = FTPControlChannel(stream: control, timeout: timeout)

            var reply = try await channel.readReply()
            guard reply.code == 220 else { throw DownloadFailure.ftp(reply.code, reply.text) }

            let user = request.credentials?.user ?? components?.user ?? "anonymous"
            let password = request.credentials?.password ?? components?.password ?? "anonymous@cdownloader.app"
            reply = try await channel.command("USER \(user)")
            if reply.code == 331 { reply = try await channel.command("PASS \(password)") }
            if reply.code == 530 { throw DownloadFailure.authenticationRequired }
            guard reply.code == 230 || reply.code == 202 else { throw DownloadFailure.ftp(reply.code, reply.text) }

            _ = try await channel.command("TYPE I")
            let path = (components?.path).flatMap { $0.isEmpty ? nil : $0 } ?? "/"

            reply = try await channel.command("SIZE \(path)")
            if reply.code == 550 { throw DownloadFailure.ftp(550, reply.text) }
            let size = reply.code == 213 ? Int64(reply.text.trimmingCharacters(in: .whitespaces)) : nil

            reply = try await channel.command("MDTM \(path)")
            let modified = reply.code == 213 ? reply.text.trimmingCharacters(in: .whitespaces) : nil

            let dataPort = try await openPassive(channel)
            let data = try await NWStream.connect(host: host, port: dataPort, timeout: timeout)
            try track(data)

            var restAccepted = false
            if request.useRange {
                reply = try await channel.command("REST \(request.offset)")
                restAccepted = reply.code == 350
                if !restAccepted && request.offset > 0 {
                    throw DownloadFailure.ftp(reply.code, "The server cannot resume (REST rejected)")
                }
            }

            reply = try await channel.command("RETR \(path)")
            guard reply.code == 125 || reply.code == 150 else { throw DownloadFailure.ftp(reply.code, reply.text) }

            let response = TransferResponse(
                statusCode: nil,
                finalURL: request.url,
                totalSize: size,
                bodyOffset: restAccepted ? request.offset : 0,
                rangeAccepted: restAccepted,
                lastModified: modified,
                acceptsRanges: restAccepted
            )
            deliver { delegate, connection in delegate.connection(connection, didReceive: response) }

            while true {
                await waitWhileSuspended()
                if isCancelled { return }
                guard let chunk = try await data.receive(maximum: 65536, timeout: timeout) else { break }
                deliver { delegate, connection in delegate.connection(connection, didReceive: chunk) }
            }

            reply = try await channel.readReply()
            if reply.code >= 400 { throw DownloadFailure.ftp(reply.code, reply.text) }
            try? await control.send(Data("QUIT\r\n".utf8))
            finish(nil)
        } catch {
            if isCancelled { return }
            finish(error as? DownloadFailure ?? .network(error.localizedDescription))
        }
    }

    /// EPSV first, PASV when the server does not understand it.
    private func openPassive(_ channel: FTPControlChannel) async throws -> UInt16 {
        var reply = try await channel.command("EPSV")
        if reply.code == 229, let port = Self.parseEPSV(reply.text) { return port }
        reply = try await channel.command("PASV")
        if reply.code == 227, let port = Self.parsePASV(reply.text) { return port }
        throw DownloadFailure.ftp(reply.code, "Passive mode not available: \(reply.text)")
    }

    /// "Entering Extended Passive Mode (|||6446|)" -> 6446
    static func parseEPSV(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let inner = text[text.index(after: open)..<close]
        let parts = inner.split(separator: inner.first ?? "|", omittingEmptySubsequences: true)
        return parts.last.flatMap { UInt16($0) }
    }

    /// "Entering Passive Mode (127,0,0,1,195,80)" -> 50000. The address is ignored; the control host is used.
    static func parsePASV(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let numbers = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else { return nil }
        return UInt16(clamping: numbers[4] * 256 + numbers[5])
    }
}

/// Reads FTP replies (including multi-line ones) and sends commands.
final class FTPControlChannel: @unchecked Sendable {
    struct Reply {
        var code: Int
        var text: String
    }

    private let stream: NWStream
    private let timeout: TimeInterval
    private var buffer = Data()

    init(stream: NWStream, timeout: TimeInterval) {
        self.stream = stream
        self.timeout = timeout
    }

    func command(_ line: String) async throws -> Reply {
        // Line breaks or NUL inside a path or login would smuggle extra commands to the server.
        guard !line.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else {
            throw DownloadFailure.unsupported("This FTP address contains line breaks and was refused")
        }
        try await stream.send(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    func readReply() async throws -> Reply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else {
            throw DownloadFailure.network("Unexpected FTP reply: \(first)")
        }
        var text = String(first.dropFirst(4))
        if first.dropFirst(3).first == "-" {
            while true {
                let line = try await readLine()
                if line.hasPrefix("\(code) ") { break }
                text += "\n" + line
            }
        }
        return Reply(code: code, text: text)
    }

    private func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var lineData = buffer[buffer.startIndex..<newline]
                if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard let more = try await stream.receive(maximum: 4096, timeout: timeout) else {
                throw DownloadFailure.connectionClosedEarly
            }
            buffer.append(more)
        }
    }
}

/// async/await wrapper around one NWConnection.
final class NWStream: @unchecked Sendable {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "NWStream")
    private let lock = NSLock()
    private var reachedEnd = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> NWStream {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw DownloadFailure.network("Bad port \(port)") }
        let stream = NWStream(connection: NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp))
        try await stream.waitUntilReady(timeout: timeout)
        return stream
    }

    private func waitUntilReady(timeout: TimeInterval) async throws {
        try await withTimeout(timeout, onTimeout: { self.cancel() }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        if once.claim() { continuation.resume(throwing: DownloadFailure.network(error.localizedDescription)) }
                    case .cancelled:
                        if once.claim() { continuation.resume(throwing: DownloadFailure.cancelled) }
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DownloadFailure.network(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Next bytes, or nil once the other side has closed.
    func receive(maximum: Int, timeout: TimeInterval) async throws -> Data? {
        if lock.withLock({ reachedEnd }) { return nil }
        return try await withTimeout(timeout, onTimeout: { self.cancel() }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        if isComplete { self.lock.withLock { self.reachedEnd = true } }
                        continuation.resume(returning: data)
                    } else if isComplete {
                        self.lock.withLock { self.reachedEnd = true }
                        continuation.resume(returning: nil)
                    } else if let error {
                        continuation.resume(throwing: DownloadFailure.network(error.localizedDescription))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Runs `operation`; after `seconds` calls `onTimeout` (which must make the operation finish) and throws.
func withTimeout<T: Sendable>(_ seconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let timedOut = OnceFlag()
    let timer = Task {
        try await Task.sleep(for: .seconds(seconds))
        if timedOut.claim() { onTimeout() }
    }
    defer { timer.cancel() }
    do {
        let value = try await operation()
        _ = timedOut.claim()
        return value
    } catch {
        if !timedOut.claim() { throw DownloadFailure.network("Timed out") }
        throw error
    }
}
