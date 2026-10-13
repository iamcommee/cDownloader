import Foundation

/// A download handed over by the browser add-on or the command line.
public struct IncomingDownload: Codable, Sendable, Equatable {
    public var url: URL
    public var referer: String?
    public var fileName: String?
    public var cookies: String?
    public var userAgent: String?
    public var mimeType: String?
    public var fileSize: Int64?
    /// "hls" for stream playlists, "youtube" for YouTube pages, otherwise a normal file.
    public var kind: String?
    /// For YouTube: a `VideoQuality` raw value ("best", "720", "audio" and so on); nil uses the app's default.
    public var quality: String?

    public init(url: URL, referer: String? = nil, fileName: String? = nil, cookies: String? = nil, userAgent: String? = nil, mimeType: String? = nil, fileSize: Int64? = nil, kind: String? = nil, quality: String? = nil) {
        self.url = url
        self.referer = referer
        self.fileName = fileName
        self.cookies = cookies
        self.userAgent = userAgent
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.kind = kind
        self.quality = quality
    }
}

/// Settings the browser add-on needs to decide what to take over.
public struct BrowserConfig: Codable, Sendable, Equatable {
    public var integrationEnabled: Bool
    public var extensions: [String]
    public var dontCaptureSites: [String]
    public var addressExceptions: [String]
    public var skipModifier: String?
    public var forceModifier: String?
    public var videoPanelEnabled: Bool
    public var videoPanelTypes: [String]
    public var videoPanelExcludedSites: [String]
    public var minimumMediaKB: Int
    /// The default YouTube quality, as a `VideoQuality` raw value.
    public var webVideoQuality: String

    public init(settings: AppSettings) {
        integrationEnabled = settings.browserIntegration
        extensions = settings.capturedExtensions
        dontCaptureSites = settings.dontCaptureSites
        addressExceptions = settings.addressExceptions
        skipModifier = settings.browser.skipModifier
        forceModifier = settings.browser.forceModifier
        videoPanelEnabled = settings.browser.videoPanelEnabled
        videoPanelTypes = settings.browser.videoPanelTypes
        videoPanelExcludedSites = settings.browser.videoPanelExcludedSites
        minimumMediaKB = settings.browser.minimumMediaKB
        webVideoQuality = settings.webVideoQuality.rawValue
    }
}

public struct IPCRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case ping
        /// Add downloads (one from a click, several from "download all links").
        case add
        case startQueue
        case getConfig
        case showWindow
    }

    public var type: Kind
    public var downloads: [IncomingDownload]?
    /// Save folder chosen on the command line.
    public var folder: String?
    /// Silent mode: no dialogs, save straight to the default folder.
    public var silent: Bool?
    /// Add to the queue without starting.
    public var addOnly: Bool?
    /// Quit the app after this download finishes.
    public var quitAfter: Bool?
    /// The page the links came from (for "download all links").
    public var pageURL: String?
    /// Show the selection list even for a single link.
    public var showList: Bool?

    public init(type: Kind, downloads: [IncomingDownload]? = nil) {
        self.type = type
        self.downloads = downloads
    }

    /// The request with the fields only the command line may set removed (folder, silent, add only, quit after).
    public func sanitizedForBrowser() -> IPCRequest {
        var clean = self
        clean.folder = nil
        clean.silent = nil
        clean.addOnly = nil
        clean.quitAfter = nil
        return clean
    }
}

public struct IPCReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var config: BrowserConfig?

    public init(ok: Bool, error: String? = nil, config: BrowserConfig? = nil) {
        self.ok = ok
        self.error = error
        self.config = config
    }
}

public enum IPCError: Error, Equatable {
    case appNotRunning
    case pathTooLong
    case invalidReply
    case timedOut
    case io(String)

    public var message: String {
        switch self {
        case .appNotRunning: "cDownloader is not running"
        case .pathTooLong: "The connection path is too long"
        case .invalidReply: "cDownloader sent an unreadable reply"
        case .timedOut: "cDownloader did not answer in time"
        case .io(let text): "Connection error: \(text)"
        }
    }
}
