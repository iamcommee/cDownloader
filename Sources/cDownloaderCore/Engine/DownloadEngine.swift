import Foundation

public struct EngineConfiguration: Sendable {
    public var maxConnections = 8
    public var minSegmentSize: Int64 = 512 * 1024
    public var timeout: TimeInterval = 30
    public var retriesPerConnection = 5
    public var retryDelay: TimeInterval = 2
    /// How often positions are saved while downloading.
    public var checkpointInterval: TimeInterval = 5
    public var ignoreModificationTimeChanges = false
    public var connectionExceptions: [ConnectionException] = []
    public var siteLogins: [SiteLogin] = []
    public var userAgent = EngineConfiguration.defaultUserAgent
    public var temporaryDirectory: URL
    public var proxy = ProxySettings()
    public var maxRedirects = 10
    /// ffmpeg, used to join separate sound tracks and to turn .ts streams into .mp4; nil turns that off.
    public var ffmpegPath: String?
    /// yt-dlp, used for YouTube and Facebook; nil when it is not installed (such downloads then fail with install advice).
    public var ytDlpPath: String?
    /// Browser whose YouTube or Facebook sign-in yt-dlp reads when the browser add-on sent none.
    public var ytDlpCookiesBrowser: String?
    /// The environment outside tools (yt-dlp) start with; their search path is extended from it.
    public var toolEnvironment = ProcessInfo.processInfo.environment
    /// How long a stopped tool gets before it is asked harder (interrupt, then terminate, then kill).
    public var toolStopGrace: TimeInterval = 5
    /// How long reading a YouTube playlist may take.
    public var playlistTimeout: TimeInterval = 60

    public static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) cDownloader/1.0"

    public init(temporaryDirectory: URL) {
        self.temporaryDirectory = temporaryDirectory
    }

    /// Engine settings taken from the user's settings.
    public init(settings: AppSettings, defaultTemporaryDirectory: URL) {
        self.init(temporaryDirectory: settings.temporaryDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultTemporaryDirectory)
        maxConnections = settings.maxConnections
        minSegmentSize = Int64(settings.minSegmentKB) * 1024
        timeout = TimeInterval(settings.timeoutSeconds)
        retriesPerConnection = settings.retriesPerConnection
        ignoreModificationTimeChanges = settings.ignoreModificationTimeChanges
        connectionExceptions = settings.connectionExceptions
        siteLogins = settings.siteLogins
        if let agent = settings.customUserAgent, !agent.isEmpty { userAgent = agent }
        proxy = settings.proxy
        ffmpegPath = FFmpeg.locate()
        ytDlpPath = YtDlp.locate()
        ytDlpCookiesBrowser = settings.webVideoCookiesBrowser
    }
}

/// Finds ffmpeg, which cDownloader uses to finish video streams: the one packed inside the app, else Homebrew's.
public enum FFmpeg {
    public static func locate(bundled: URL? = AppPaths.bundledToolsDirectory, fallbacks: [String] = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) -> String? {
        let packed = bundled.map { [$0.appendingPathComponent("ffmpeg").path] } ?? []
        return (packed + fallbacks).first(where: YtDlp.isRunnable)
    }
}

/// Live numbers for the list and the progress window.
public struct DownloadProgressSnapshot: Sendable, Equatable {
    public var id: UUID
    public var downloadedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double
    public var activeConnections: Int
    public var resumable: Bool
    public var segments: SegmentProgress

    public var secondsLeft: Double? {
        guard let totalBytes, bytesPerSecond > 0 else { return nil }
        return Double(max(0, totalBytes - downloadedBytes)) / bytesPerSecond
    }
}

/// Something that downloads one item and reports `DownloadJob.Event`s.
public protocol DownloadRunner: AnyObject, Sendable {
    var id: UUID { get }
    var item: DownloadItem { get }
    func start()
    func pause()
}

/// Creates download jobs that share transports, the speed limiter and the quota.
public final class DownloadEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: EngineConfiguration
    private var httpTransport: HTTPTransport
    private var extraTransports: [String: Transport] = [:]
    public let secrets: SecretStore
    public let limiter: SpeedLimiter
    public let quota: DownloadQuota?
    let clock: TimeSource

    public init(configuration: EngineConfiguration, secrets: SecretStore, limiter: SpeedLimiter = SpeedLimiter(), quota: DownloadQuota? = nil, clock: TimeSource = SystemTimeSource()) {
        self.configuration = configuration
        self.secrets = secrets
        self.limiter = limiter
        self.quota = quota
        self.clock = clock
        self.httpTransport = HTTPTransport(options: Self.httpOptions(configuration, secrets: secrets))
        self.extraTransports["ftp"] = FTPTransport(options: Self.ftpOptions(configuration))
    }

    public var currentConfiguration: EngineConfiguration { lock.withLock { configuration } }

    /// New settings apply to connections opened from now on.
    public func update(configuration newValue: EngineConfiguration) {
        let old = lock.withLock { () -> HTTPTransport in
            let old = httpTransport
            configuration = newValue
            httpTransport = HTTPTransport(options: Self.httpOptions(newValue, secrets: secrets))
            extraTransports["ftp"] = FTPTransport(options: Self.ftpOptions(newValue))
            return old
        }
        old.finishTasksLater()
    }

    /// Registers a transport for another URL scheme (FTP).
    public func register(_ transport: Transport, forScheme scheme: String) {
        lock.withLock { extraTransports[scheme.lowercased()] = transport }
    }

    func transport(for url: URL) -> Transport? {
        let scheme = url.scheme?.lowercased() ?? ""
        return lock.withLock {
            if scheme == "http" || scheme == "https" { return httpTransport }
            return extraTransports[scheme]
        }
    }

    public func makeJob(for item: DownloadItem, onEvent: @escaping @Sendable (DownloadJob.Event) -> Void) -> DownloadJob {
        DownloadJob(item: item, engine: self, configuration: currentConfiguration, onEvent: onEvent)
    }

    /// A file job, an HLS job or a yt-dlp job, depending on the item's kind.
    public func makeRunner(for item: DownloadItem, onEvent: @escaping @Sendable (DownloadJob.Event) -> Void) -> DownloadRunner {
        switch item.kind {
        case .file: makeJob(for: item, onEvent: onEvent)
        case .hls: HLSJob(item: item, engine: self, configuration: currentConfiguration, onEvent: onEvent)
        case .webVideo: YtDlpJob(item: item, engine: self, configuration: currentConfiguration, onEvent: onEvent)
        }
    }

    private static func ftpOptions(_ configuration: EngineConfiguration) -> FTPTransport.Options {
        var options = FTPTransport.Options()
        options.timeout = configuration.timeout
        return options
    }

    private static func httpOptions(_ configuration: EngineConfiguration, secrets: SecretStore) -> HTTPTransport.Options {
        var options = HTTPTransport.Options()
        options.timeout = configuration.timeout
        options.maxRedirects = configuration.maxRedirects
        options.proxy = configuration.proxy
        if let user = configuration.proxy.username, !user.isEmpty {
            options.proxyCredentials = Credentials(user: user, password: secrets.password(for: ProxySettings.credentialKey) ?? "")
        }
        return options
    }
}
