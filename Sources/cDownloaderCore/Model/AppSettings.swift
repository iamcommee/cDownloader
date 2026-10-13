import Foundation

public enum ProxyMode: String, Codable, Sendable, CaseIterable {
    case none
    case system
    case manual
}

public struct ProxySettings: Codable, Sendable, Equatable {
    public static let credentialKey = "proxy"

    public var mode: ProxyMode = .system
    public var httpHost = ""
    public var httpPort = 8080
    /// When false, HTTPS uses `httpsHost`/`httpsPort`.
    public var sameProxyForHTTPS = true
    public var httpsHost = ""
    public var httpsPort = 8080
    public var socksHost = ""
    public var socksPort = 1080
    public var username: String?
    /// Hosts that skip the proxy; `*` wildcards allowed.
    public var bypass: [String] = ["localhost", "127.0.0.1", "*.local"]
    public var ftpPassiveMode = true

    public init() {}
}

public struct SiteLogin: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var urlPrefix: String
    public var username: String

    public init(id: UUID = UUID(), urlPrefix: String, username: String) {
        self.id = id
        self.urlPrefix = urlPrefix
        self.username = username
    }

    public var credentialKey: String { "sitelogin.\(id.uuidString)" }
}

public struct ConnectionException: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var hostPattern: String
    public var maxConnections: Int

    public init(id: UUID = UUID(), hostPattern: String, maxConnections: Int) {
        self.id = id
        self.hostPattern = hostPattern
        self.maxConnections = maxConnections
    }
}

public struct QuotaSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var megabytes = 200
    public var hours = 1

    public init(enabled: Bool = false, megabytes: Int = 200, hours: Int = 1) {
        self.enabled = enabled
        self.megabytes = megabytes
        self.hours = hours
    }
}

public struct SpeedLimiterSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var bytesPerSecond: Int64 = 500 * 1024
    public var turnOnAtStartup = false

    public init() {}
}

public struct ScanSettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var executablePath = ""
    /// `%f` is replaced by the file path; when absent the path is appended.
    public var arguments = ""

    public init() {}
}

public enum SoundEvent: String, Codable, Sendable, CaseIterable {
    case downloadComplete
    case downloadFailed
    case queueStarted
    case queueFinished
}

public struct SoundSettings: Codable, Sendable, Equatable {
    /// Event name to system sound name (for example "Glass") or a file path.
    public var sounds: [String: String] = [
        SoundEvent.downloadComplete.rawValue: "Glass",
        SoundEvent.downloadFailed.rawValue: "Basso",
        SoundEvent.queueStarted.rawValue: "Pop",
        SoundEvent.queueFinished.rawValue: "Hero",
    ]
    public var enabled: Set<String> = []

    public init() {}
}

public struct BrowserSettings: Codable, Sendable, Equatable {
    /// Option key held while clicking lets the browser download instead.
    public var skipModifier: String? = "alt"
    /// Key that forces a takeover even for unlisted types; nil turns it off.
    public var forceModifier: String?
    public var videoPanelEnabled = true
    public var videoPanelTypes = ["mp4", "webm", "m4v", "mov", "mkv", "flv", "mp3", "m4a", "aac", "ogg", "wav", "m3u8"]
    public var videoPanelExcludedSites: [String] = []
    public var minimumMediaKB = 300
    public var panelForSelectedLinks = true

    public init() {}
}

public enum ProgressWindowMode: String, Codable, Sendable, CaseIterable {
    case show
    case minimized
    case hidden
}

public struct AppSettings: Codable, Sendable, Equatable {
    public static let defaultCapturedExtensions = [
        "3gp", "7z", "aac", "ace", "aif", "aiff", "apk", "arj", "asf", "avi", "bin", "bz2", "dmg", "exe", "flac",
        "gz", "gzip", "img", "iso", "lzh", "m3u8", "m4a", "m4v", "mkv", "mov", "mp3", "mp4", "mpa", "mpe", "mpeg", "mpg",
        "msi", "ogg", "ogv", "pdf", "pkg", "pps", "ppt", "qt", "r0*", "r1*", "ra", "rar", "rm", "rmvb", "sea",
        "sit", "sitx", "tar", "tgz", "tif", "tiff", "wav", "webm", "wma", "wmv", "xz", "z", "zip",
    ]

    // General
    public var launchAtLogin = false
    public var browserIntegration = true
    public var clipboardMonitoring = true
    public var showDropTarget = false
    public var showMenuBarIcon = true
    // File types
    public var capturedExtensions = defaultCapturedExtensions
    public var dontCaptureSites = ["*.update.microsoft.com", "*.windowsupdate.com", "*.mzstatic.com"]
    public var addressExceptions: [String] = []
    // Connection
    public var maxConnections = 8
    public var minSegmentKB = 512
    public var timeoutSeconds = 30
    public var retriesPerConnection = 5
    public var connectionExceptions: [ConnectionException] = []
    public var quota = QuotaSettings()
    // Save to
    public var temporaryDirectory: String?
    public var rememberLastSavePath = true
    // Downloads
    public var showStartDialog = true
    public var progressWindow: ProgressWindowMode = .show
    public var showCompleteDialog = true
    public var startWhileShowingInfo = true
    public var ignoreModificationTimeChanges = false
    public var customUserAgent: String?
    public var scan = ScanSettings()
    // Other tabs
    public var proxy = ProxySettings()
    public var siteLogins: [SiteLogin] = []
    public var sounds = SoundSettings()
    public var speedLimiter = SpeedLimiterSettings()
    public var browser = BrowserSettings()
    // Video sites (YouTube, through yt-dlp)
    public var webVideoQuality: VideoQuality = .best
    /// Browser whose YouTube sign-in yt-dlp may read for links added in the app ("chrome", "safari" ...); nil for none.
    public var webVideoCookiesBrowser: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        launchAtLogin = try c.value(.launchAtLogin, default: d.launchAtLogin)
        browserIntegration = try c.value(.browserIntegration, default: d.browserIntegration)
        clipboardMonitoring = try c.value(.clipboardMonitoring, default: d.clipboardMonitoring)
        showDropTarget = try c.value(.showDropTarget, default: d.showDropTarget)
        showMenuBarIcon = try c.value(.showMenuBarIcon, default: d.showMenuBarIcon)
        capturedExtensions = try c.value(.capturedExtensions, default: d.capturedExtensions)
        dontCaptureSites = try c.value(.dontCaptureSites, default: d.dontCaptureSites)
        addressExceptions = try c.value(.addressExceptions, default: d.addressExceptions)
        maxConnections = try c.value(.maxConnections, default: d.maxConnections)
        minSegmentKB = try c.value(.minSegmentKB, default: d.minSegmentKB)
        timeoutSeconds = try c.value(.timeoutSeconds, default: d.timeoutSeconds)
        retriesPerConnection = try c.value(.retriesPerConnection, default: d.retriesPerConnection)
        connectionExceptions = try c.value(.connectionExceptions, default: d.connectionExceptions)
        quota = try c.value(.quota, default: d.quota)
        temporaryDirectory = try c.decodeIfPresent(String.self, forKey: .temporaryDirectory)
        rememberLastSavePath = try c.value(.rememberLastSavePath, default: d.rememberLastSavePath)
        showStartDialog = try c.value(.showStartDialog, default: d.showStartDialog)
        progressWindow = try c.value(.progressWindow, default: d.progressWindow)
        showCompleteDialog = try c.value(.showCompleteDialog, default: d.showCompleteDialog)
        startWhileShowingInfo = try c.value(.startWhileShowingInfo, default: d.startWhileShowingInfo)
        ignoreModificationTimeChanges = try c.value(.ignoreModificationTimeChanges, default: d.ignoreModificationTimeChanges)
        customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent)
        scan = try c.value(.scan, default: d.scan)
        proxy = try c.value(.proxy, default: d.proxy)
        siteLogins = try c.value(.siteLogins, default: d.siteLogins)
        sounds = try c.value(.sounds, default: d.sounds)
        speedLimiter = try c.value(.speedLimiter, default: d.speedLimiter)
        browser = try c.value(.browser, default: d.browser)
        webVideoQuality = try c.value(.webVideoQuality, default: d.webVideoQuality)
        webVideoCookiesBrowser = try c.decodeIfPresent(String.self, forKey: .webVideoCookiesBrowser)
    }
}

/// Everything in the download list that is saved between launches.
public struct LibraryState: Codable, Sendable, Equatable {
    public var downloads: [DownloadItem]
    public var queues: [DownloadQueue]
    public var categories: [DownloadCategory]

    public init(downloads: [DownloadItem] = [], queues: [DownloadQueue] = DownloadQueue.defaults(), categories: [DownloadCategory] = []) {
        self.downloads = downloads
        self.queues = queues
        self.categories = categories
    }
}
