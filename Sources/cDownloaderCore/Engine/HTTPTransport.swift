import Foundation

/// HTTP and HTTPS connections on one URLSession. Each connection is one data task with an open-ended Range.
public final class HTTPTransport: NSObject, Transport, URLSessionDataDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        public var timeout: TimeInterval = 30
        public var maxRedirects = 10
        public var proxy = ProxySettings()
        public var proxyCredentials: Credentials?

        public init() {}
    }

    private let lock = NSLock()
    private var connections: [Int: HTTPConnection] = [:]
    private var session: URLSession!
    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.timeoutIntervalForRequest = options.timeout
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = ProxyConfigurator.connectionProxyDictionary(for: options.proxy)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    public func open(_ request: TransferRequest, delegate: TransferConnectionDelegate, queue: DispatchQueue) -> TransferConnection {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = options.timeout
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if request.useRange {
            urlRequest.setValue("bytes=\(request.offset)-", forHTTPHeaderField: "Range")
            if let validator = request.validator { urlRequest.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        if let credentials = request.credentials {
            let token = Data("\(credentials.user):\(credentials.password)".utf8).base64EncodedString()
            urlRequest.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: urlRequest)
        let connection = HTTPConnection(task: task, request: request, delegate: delegate, queue: queue, transport: self)
        lock.withLock { connections[task.taskIdentifier] = connection }
        task.resume()
        return connection
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }

    /// Lets running tasks finish, then releases the session.
    func finishTasksLater() {
        session.finishTasksAndInvalidate()
    }

    fileprivate func forget(_ task: URLSessionTask) {
        lock.withLock { _ = connections.removeValue(forKey: task.taskIdentifier) }
    }

    private func connection(for task: URLSessionTask) -> HTTPConnection? {
        lock.withLock { connections[task.taskIdentifier] }
    }

    // MARK: URLSession delegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        guard let connection = connection(for: dataTask) else { return }
        connection.deliver(response: Self.makeResponse(response, requestedOffset: connection.request.offset, requestedRange: connection.request.useRange))
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        connection(for: dataTask)?.deliver(data: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let connection = connection(for: task) else { return }
        forget(task)
        let failure: DownloadFailure? = error.map { error in
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return .cancelled }
            return .network(nsError.localizedDescription)
        }
        connection.deliver(completion: failure)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let connection = connection(for: task) else { return completionHandler(nil) }
        connection.redirects += 1
        guard connection.redirects <= options.maxRedirects else {
            connection.tooManyRedirects = true
            return completionHandler(nil)
        }
        var next = request
        let original = task.originalRequest
        let sameOrigin = original?.url.flatMap { from in request.url.map { from.sharesCredentials(with: $0) } } ?? false
        let private_ = ["cookie", "authorization"]
        for (name, value) in original?.allHTTPHeaderFields ?? [:] where next.value(forHTTPHeaderField: name) == nil {
            if !sameOrigin, private_.contains(name.lowercased()) { continue }
            next.setValue(value, forHTTPHeaderField: name)
        }
        if !sameOrigin {
            // The browser's cookies and the user's login belong to the original site only.
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return completionHandler(.performDefaultHandling, nil)
        }
        let ownSite = connection(for: task).map { connection in
            space.host.lowercased() == connection.request.url.host?.lowercased()
        } ?? false
        let credentials = space.isProxy() ? options.proxyCredentials : (ownSite ? connection(for: task)?.request.credentials : nil)
        if let credentials, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, URLCredential(user: credentials.user, password: credentials.password, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func makeResponse(_ response: URLResponse, requestedOffset: Int64, requestedRange: Bool) -> TransferResponse {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        func header(_ name: String) -> String? { http?.value(forHTTPHeaderField: name) }
        var total: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        var bodyOffset: Int64 = 0
        var accepted = false
        if status == 206, let range = header("Content-Range").flatMap(parseContentRange) {
            bodyOffset = range.start
            total = range.total
            accepted = true
        } else if status == 206 {
            bodyOffset = requestedOffset
            total = nil
            accepted = true
        }
        return TransferResponse(
            statusCode: status,
            finalURL: response.url ?? URL(string: "about:blank")!,
            totalSize: total,
            bodyOffset: bodyOffset,
            rangeAccepted: accepted,
            etag: header("ETag"),
            lastModified: header("Last-Modified"),
            contentDisposition: header("Content-Disposition"),
            mimeType: response.mimeType,
            acceptsRanges: header("Accept-Ranges")?.lowercased().contains("bytes") == true
        )
    }

    /// "bytes 100-199/1000" -> start 100, total 1000 ("*" total -> nil).
    static func parseContentRange(_ value: String) -> (start: Int64, total: Int64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let spec = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, Int64(parts[1]))
    }
}

final class HTTPConnection: TransferConnection, @unchecked Sendable {
    let task: URLSessionDataTask
    let request: TransferRequest
    private weak var transport: HTTPTransport?
    private let queue: DispatchQueue
    private var delegate: TransferConnectionDelegate?
    var redirects = 0
    var tooManyRedirects = false

    init(task: URLSessionDataTask, request: TransferRequest, delegate: TransferConnectionDelegate, queue: DispatchQueue, transport: HTTPTransport) {
        self.task = task
        self.request = request
        self.delegate = delegate
        self.queue = queue
        self.transport = transport
    }

    func deliver(response: TransferResponse) {
        let redirectsExceeded = tooManyRedirects
        queue.async { [self] in
            guard let delegate else { return }
            if redirectsExceeded {
                self.delegate = nil
                task.cancel()
                return delegate.connection(self, didCompleteWith: .tooManyRedirects)
            }
            delegate.connection(self, didReceive: response)
        }
    }

    func deliver(data: Data) {
        queue.async { [self] in delegate?.connection(self, didReceive: data) }
    }

    func deliver(completion: DownloadFailure?) {
        queue.async { [self] in
            let delegate = self.delegate
            self.delegate = nil
            delegate?.connection(self, didCompleteWith: completion)
        }
    }

    func cancel() {
        delegate = nil
        task.cancel()
        transport?.forget(task)
    }

    func suspend() { task.suspend() }
    func resume() { task.resume() }
}
