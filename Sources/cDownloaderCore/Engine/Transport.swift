import Foundation

public struct Credentials: Sendable, Equatable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// One request for bytes of a remote file, starting at `offset`.
public struct TransferRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var credentials: Credentials?
    /// Sent as If-Range so a changed file comes back whole instead of as a mismatched piece.
    public var validator: String?
    public var offset: Int64
    /// When false no Range header is sent (servers known not to support ranges).
    public var useRange: Bool

    public init(url: URL, headers: [String: String] = [:], credentials: Credentials? = nil, validator: String? = nil, offset: Int64 = 0, useRange: Bool = true) {
        self.url = url
        self.headers = headers
        self.credentials = credentials
        self.validator = validator
        self.offset = offset
        self.useRange = useRange
    }
}

/// What the server said before sending the body.
public struct TransferResponse: Sendable, Equatable {
    /// HTTP status; nil for FTP.
    public var statusCode: Int?
    public var finalURL: URL
    /// Length of the whole remote file, when known.
    public var totalSize: Int64?
    /// Offset of the first body byte in the remote file.
    public var bodyOffset: Int64
    /// The server honored the requested offset (HTTP 206 or FTP REST).
    public var rangeAccepted: Bool
    public var etag: String?
    public var lastModified: String?
    public var contentDisposition: String?
    public var mimeType: String?
    /// The server advertises byte-range support (Accept-Ranges: bytes, a 206, or FTP REST).
    public var acceptsRanges: Bool

    public init(statusCode: Int?, finalURL: URL, totalSize: Int64?, bodyOffset: Int64, rangeAccepted: Bool, etag: String? = nil, lastModified: String? = nil, contentDisposition: String? = nil, mimeType: String? = nil, acceptsRanges: Bool = false) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.totalSize = totalSize
        self.bodyOffset = bodyOffset
        self.rangeAccepted = rangeAccepted
        self.etag = etag
        self.lastModified = lastModified
        self.contentDisposition = contentDisposition
        self.mimeType = mimeType
        self.acceptsRanges = acceptsRanges || rangeAccepted
    }
}

/// Callbacks from one connection, delivered in order on the queue given to `open`.
public protocol TransferConnectionDelegate: AnyObject, Sendable {
    func connection(_ connection: TransferConnection, didReceive response: TransferResponse)
    func connection(_ connection: TransferConnection, didReceive data: Data)
    func connection(_ connection: TransferConnection, didCompleteWith error: DownloadFailure?)
}

public protocol TransferConnection: AnyObject, Sendable {
    func cancel()
    /// Stops reading for a while (speed limiter); the server is slowed by TCP flow control.
    func suspend()
    func resume()
}

public protocol Transport: AnyObject, Sendable {
    func open(_ request: TransferRequest, delegate: TransferConnectionDelegate, queue: DispatchQueue) -> TransferConnection
    func invalidate()
}

public enum DownloadFailure: Error, Sendable, Equatable {
    case http(Int)
    case ftp(Int, String)
    case authenticationRequired
    case tooManyRedirects
    case network(String)
    case fileSystem(String)
    case connectionClosedEarly
    case unexpectedRange
    case protectedContent
    case unsupported(String)
    case cancelled

    public var message: String {
        switch self {
        case .http(404): "File not found on the server (HTTP 404)"
        case .http(403): "Access denied by the server (HTTP 403)"
        case .http(410): "File no longer exists on the server (HTTP 410)"
        case .http(let code): "Server error (HTTP \(code))"
        case .ftp(550, _): "File not found on the FTP server (550)"
        case .ftp(let code, let text): "FTP server error \(code): \(text)"
        case .authenticationRequired: "Authorization required: the server rejected the login (HTTP 401)"
        case .tooManyRedirects: "Too many redirects"
        case .network(let text): "Network error: \(text)"
        case .fileSystem(let text): "Cannot write the file: \(text)"
        case .connectionClosedEarly: "The server closed the connection early"
        case .unexpectedRange: "The server sent a different part of the file than requested"
        case .protectedContent: "This media is protected (DRM) and cannot be downloaded"
        case .unsupported(let text): text
        case .cancelled: "Cancelled"
        }
    }

    /// Network hiccups and server overload are worth retrying; a missing file or a wrong password is not.
    public var isRetryable: Bool {
        switch self {
        case .http(let code): code >= 500 || code == 408 || code == 429
        case .ftp(let code, _): (400..<500).contains(code)
        case .network, .connectionClosedEarly, .unexpectedRange: true
        default: false
        }
    }
}
