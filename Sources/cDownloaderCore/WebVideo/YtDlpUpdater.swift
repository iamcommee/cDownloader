import Foundation

/// Keeps the yt-dlp packed inside the app usable and current. At launch, `prepare` copies it into the app's own
/// folder, because macOS refuses to start the packed file when the app was downloaded through a browser (the
/// download mark), while a copy the app made itself starts fine. `updateIfDue` then lets that copy update itself
/// about once a day, since YouTube changes often and an old yt-dlp stops working.
public struct YtDlpUpdater: Sendable {
    /// The app's own copy: yt-dlp, its version in yt-dlp.version, and the time of the last check in yt-dlp.checked.
    public var toolsDirectory: URL
    /// The copy packed inside the app.
    public var bundledDirectory: URL?
    /// The packed copy's version. It cannot sit next to the copy: the app's programs folder may hold only programs.
    public var bundledVersionFile: URL?
    public var interval: TimeInterval = 86_400
    public var timeout: TimeInterval = 600
    public var environment: [String: String]

    public enum Outcome: Equatable, Sendable {
        case notDue, noTool, upToDate(String), updated(String), failed(String)
    }

    public init(
        toolsDirectory: URL = AppPaths.toolsDirectory, bundledDirectory: URL? = AppPaths.bundledToolsDirectory,
        bundledVersionFile: URL? = AppPaths.bundledYtDlpVersionFile, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.toolsDirectory = toolsDirectory
        self.bundledDirectory = bundledDirectory
        self.bundledVersionFile = bundledVersionFile
        self.environment = environment
    }

    var ownURL: URL { toolsDirectory.appendingPathComponent("yt-dlp") }
    var ownVersionURL: URL { toolsDirectory.appendingPathComponent("yt-dlp.version") }
    var stagingURL: URL { toolsDirectory.appendingPathComponent("yt-dlp.new") }
    var stampURL: URL { toolsDirectory.appendingPathComponent("yt-dlp.checked") }

    /// Copies the packed yt-dlp into the app's own folder when that holds none, or an older one, and clears the
    /// download mark from the copy. A copy that updated itself past the packed one is kept.
    public func prepare() {
        defer { Self.clearDownloadMark(ownURL) }
        guard let bundledDirectory else { return }
        let packed = bundledDirectory.appendingPathComponent("yt-dlp")
        guard YtDlp.isRunnable(packed.path) else { return }
        let packedVersion = bundledVersionFile.flatMap(Self.version(at:)) ?? ""
        if YtDlp.isRunnable(ownURL.path), let ownVersion = Self.version(at: ownVersionURL),
           !Self.isNewer(packedVersion, than: ownVersion) {
            return
        }
        do {
            try stage(from: packed)
            try install(version: packedVersion)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
        }
    }

    /// Lets the own copy update itself when the last successful check is at least `interval` old. The update runs
    /// on a spare copy, which replaces the own copy only when it starts and is newer, so a failed or broken update
    /// never leaves YouTube downloads without a working yt-dlp. A failed check is tried again at the next call.
    public func updateIfDue(now: Date = Date()) async -> Outcome {
        if let last = lastCheck(), last <= now, now.timeIntervalSince(last) < interval { return .notDue }
        guard YtDlp.isRunnable(ownURL.path) else { return .noTool }
        let ownVersion = Self.version(at: ownVersionURL) ?? ""
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        do {
            try stage(from: ownURL)
            let update = try await YtDlp.run(stagingURL.path, arguments: ["--ignore-config", "-U"], environment: environment, timeout: timeout)
            if update.timedOut { return .failed("The yt-dlp update took too long.") }
            guard update.status == 0 else { return .failed(YtDlp.failureMessage(stderr: update.errors, exitCode: update.status)) }
            let check = try await YtDlp.run(stagingURL.path, arguments: ["--version"], environment: environment, timeout: timeout)
            let newVersion = check.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard check.status == 0, !check.timedOut, !newVersion.isEmpty else { return .failed("The updated yt-dlp does not start.") }
            let newer = Self.isNewer(newVersion, than: ownVersion)
            if newer { try install(version: newVersion) }
            try Data(String(now.timeIntervalSince1970).utf8).write(to: stampURL, options: .atomic)
            return newer ? .updated(newVersion) : .upToDate(ownVersion.isEmpty ? newVersion : ownVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// yt-dlp versions are dates with optional extra parts ("2026.08.19", "2026.08.19.1"), compared part by part
    /// as numbers. A missing part or a word counts as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let x = index < left.count ? left[index] : 0
            let y = index < right.count ? right[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Files

    /// A runnable spare copy of `source`, without the download mark, next to the own copy.
    private func stage(from source: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: stagingURL)
        try fileManager.copyItem(at: source, to: stagingURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)
        Self.clearDownloadMark(stagingURL)
    }

    /// Puts the spare copy in place of the own copy in one step, so a running download never sees a half file.
    private func install(version: String) throws {
        guard rename(stagingURL.path, ownURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: ownURL.path])
        }
        try Data(version.utf8).write(to: ownVersionURL, options: .atomic)
    }

    private func lastCheck() -> Date? {
        guard let text = try? String(contentsOf: stampURL, encoding: .utf8), let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The version in a yt-dlp.version file; nil when there is none.
    public static func version(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// Removes the mark macOS puts on files downloaded through a browser; macOS stops a marked yt-dlp from starting.
    static func clearDownloadMark(_ url: URL) {
        removexattr(url.path, "com.apple.quarantine", 0)
    }
}
