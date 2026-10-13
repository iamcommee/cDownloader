import Foundation
import Network

/// A small HTTP/1.1 server bound to 127.0.0.1 for integration tests.
/// Every response closes its connection, which keeps the parser simple.
final class LocalHTTPServer: @unchecked Sendable {
    struct Resource: Sendable {
        var body: Data
        var contentType = "application/octet-stream"
        var status = 200
        var etag: String?
        var lastModified: String?
        var contentDisposition: String?
        var supportsRanges = true
        /// Answer ranges even when If-Range no longer matches (a misbehaving server).
        var ignoreIfRange = false
        var sendContentLength = true
        var bytesPerSecond: Int?
        /// The next `dropCount` body responses are cut off after `dropAfterBytes`.
        var dropAfterBytes: Int?
        var dropCount = 0
        var basicAuth: Credentials?
        var redirectTo: String?
        var extraHeaders: [String: String] = [:]

        init(body: Data, contentType: String = "application/octet-stream") {
            self.body = body
            self.contentType = contentType
        }
    }

    struct Credentials: Sendable {
        var user: String
        var password: String
    }

    struct RecordedRequest: Sendable {
        var method: String
        var path: String
        /// Header names are lowercased.
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var resources: [String: Resource] = [:]
    private var log: [RecordedRequest] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var activeBodies = 0
    private var peakBodies = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        // The port is bound right after start; poll it instead of blocking on a state callback.
        let deadline = Date().addingTimeInterval(5)
        while (listener.port?.rawValue ?? 0) == 0, Date() < deadline {
            usleep(1000)
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    deinit { stop() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func url(_ path: String) -> URL {
        URL(string: path.hasPrefix("/") ? path : "/" + path, relativeTo: baseURL)!.absoluteURL
    }

    func set(_ path: String, _ resource: Resource) {
        lock.withLock { resources[path] = resource }
    }

    func update(_ path: String, _ change: (inout Resource) -> Void) {
        lock.withLock {
            if var resource = resources[path] {
                change(&resource)
                resources[path] = resource
            }
        }
    }

    func remove(_ path: String) {
        lock.withLock { _ = resources.removeValue(forKey: path) }
    }

    var requests: [RecordedRequest] { lock.withLock { log } }

    /// Highest number of response bodies that were being sent at the same time.
    var peakConcurrentBodies: Int { lock.withLock { peakBodies } }

    private func bodyStarted() {
        lock.withLock {
            activeBodies += 1
            peakBodies = max(peakBodies, activeBodies)
        }
    }

    private func bodyEnded() {
        lock.withLock { activeBodies -= 1 }
    }

    func requests(for path: String) -> [RecordedRequest] {
        requests.filter { $0.path == path || $0.path.hasPrefix(path + "?") }
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }
        open.forEach { $0.cancel() }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "LocalHTTPServer.connection"))
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(connection, head: head)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return connection.cancel() }
        let method = String(requestLine[0])
        let path = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let (resource, shouldDrop) = lock.withLock { () -> (Resource?, Bool) in
            log.append(RecordedRequest(method: method, path: path, headers: headers))
            let key = resources[path] != nil ? path : String(path.split(separator: "?").first ?? "")
            guard var resource = resources[key] else { return (nil, false) }
            var drop = false
            if resource.dropCount > 0, resource.dropAfterBytes != nil, method != "HEAD" {
                resource.dropCount -= 1
                resources[key] = resource
                drop = true
            }
            return (resource, drop)
        }

        guard let resource else {
            return send(connection, status: 404, headers: ["Content-Length": "9"], body: Data("not found".utf8))
        }
        if let target = resource.redirectTo {
            return send(connection, status: 302, headers: ["Location": target, "Content-Length": "0"], body: Data())
        }
        if let credentials = resource.basicAuth {
            let expected = "Basic " + Data("\(credentials.user):\(credentials.password)".utf8).base64EncodedString()
            if headers["authorization"] != expected {
                return send(connection, status: 401, headers: ["WWW-Authenticate": "Basic realm=\"test\"", "Content-Length": "0"], body: Data())
            }
        }
        if resource.status != 200 {
            return send(connection, status: resource.status, headers: ["Content-Length": "\(resource.body.count)"], body: resource.body)
        }

        let total = resource.body.count
        var status = 200
        var slice = resource.body
        var responseHeaders: [String: String] = ["Content-Type": resource.contentType]
        if resource.supportsRanges { responseHeaders["Accept-Ranges"] = "bytes" }
        if let etag = resource.etag { responseHeaders["ETag"] = etag }
        if let lastModified = resource.lastModified { responseHeaders["Last-Modified"] = lastModified }
        if let disposition = resource.contentDisposition { responseHeaders["Content-Disposition"] = disposition }
        for (name, value) in resource.extraHeaders { responseHeaders[name] = value }

        if resource.supportsRanges, let range = headers["range"], let bounds = Self.parseRange(range, total: total) {
            let validator = headers["if-range"]
            let validatorMatches = resource.ignoreIfRange || validator == nil || validator == resource.etag || validator == resource.lastModified
            if validatorMatches {
                if bounds.lowerBound >= total {
                    return send(connection, status: 416, headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0"], body: Data())
                }
                status = 206
                slice = resource.body.subdata(in: bounds)
                responseHeaders["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(total)"
            }
        }
        if resource.sendContentLength { responseHeaders["Content-Length"] = "\(slice.count)" }
        if method == "HEAD" { slice = Data() }
        send(
            connection, status: status, headers: responseHeaders, body: slice,
            bytesPerSecond: resource.bytesPerSecond,
            dropAfter: shouldDrop ? resource.dropAfterBytes : nil
        )
    }

    static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]) {
            return max(0, total - suffix)..<total
        }
        guard let start = Int(parts[0]) else { return nil }
        let end = Int(parts[1]).map { min($0 + 1, total) } ?? total
        return start..<max(start, end)
    }

    private func send(
        _ connection: NWConnection, status: Int, headers: [String: String], body: Data,
        bytesPerSecond: Int? = nil, dropAfter: Int? = nil
    ) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        let tracked = !body.isEmpty
        if tracked { bodyStarted() }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return connection.cancel() }
            self.sendBody(connection, body: body, offset: 0, bytesPerSecond: bytesPerSecond, dropAfter: dropAfter, tracked: tracked)
        })
    }

    private func sendBody(_ connection: NWConnection, body: Data, offset: Int, bytesPerSecond: Int?, dropAfter: Int?, tracked: Bool) {
        if let dropAfter, offset >= dropAfter {
            if tracked { bodyEnded() }
            // Close the socket (FIN) so the client sees the body end short of Content-Length right away.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        guard offset < body.count else {
            if tracked { bodyEnded() }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        var chunkSize = bytesPerSecond.map { max(1, min(16384, $0 / 10)) } ?? 65536
        if let dropAfter { chunkSize = min(chunkSize, dropAfter - offset) }
        let end = min(body.count, offset + chunkSize)
        let chunk = body.subdata(in: (body.startIndex + offset)..<(body.startIndex + end))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return connection.cancel() }
            guard error == nil else {
                if tracked { self.bodyEnded() }
                return connection.cancel()
            }
            let next: @Sendable () -> Void = { self.sendBody(connection, body: body, offset: end, bytesPerSecond: bytesPerSecond, dropAfter: dropAfter, tracked: tracked) }
            if let bytesPerSecond {
                let delay = Double(chunk.count) / Double(bytesPerSecond)
                DispatchQueue(label: "LocalHTTPServer.throttle").asyncAfter(deadline: .now() + delay, execute: next)
            } else {
                next()
            }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 302: "Found"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

extension Data {
    /// Deterministic pseudo-random bytes so corrupted offsets show up in comparisons.
    static func pattern(count: Int, seed: UInt32 = 1) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count {
                state = state &* 1_664_525 &+ 1_013_904_223
                buffer[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return data
    }
}
