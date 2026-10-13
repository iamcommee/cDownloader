import Foundation

/// yt-dlp, the program cDownloader uses (when installed) to download from YouTube. YouTube splits picture
/// and sound and scrambles the addresses of the pieces, and changes how every few weeks; yt-dlp's maintainers
/// keep up with that, so the app hands the work to it instead of copying it.
public enum YtDlp {
    public static let missingMessage = "YouTube downloads need yt-dlp, which comes with cDownloader. Reinstall cDownloader, or install it with Homebrew: brew install yt-dlp"
    public static let botCheckMessage = "YouTube asked to confirm you're not a bot. Start the download from the browser add-on, which passes your YouTube sign-in, or choose a browser under Settings > Video Sites."
    public static let playlistMessage = "This link is a playlist whose videos could not be read. Check the address, then add it again."
    public static let noFileMessage = "yt-dlp finished without leaving a file."

    public static let searchPaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]
    /// Where Homebrew puts the tools yt-dlp itself looks for (deno for YouTube's scripts, ffmpeg).
    static let toolFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The app's own copy (kept up to date) first, then the one packed inside the app, then Homebrew's.
    public static func locate(own: URL? = AppPaths.toolsDirectory, bundled: URL? = AppPaths.bundledToolsDirectory, fallbacks: [String] = searchPaths) -> String? {
        let packed = [own, bundled].compactMap { $0?.appendingPathComponent("yt-dlp").path }
        return (packed + fallbacks).first(where: isRunnable)
    }

    /// A runnable file; a folder with the tool's name does not count.
    static func isRunnable(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The `-f` choice for a quality. Joining separate picture and sound needs ffmpeg; without it only
    /// formats that already carry both can be used, which YouTube offers in smaller sizes only.
    public static func formatArguments(quality: VideoQuality, ffmpegPath: String?) -> [String] {
        let sorting = ["-S", "res,fps,vcodec:h264,acodec:aac", "--merge-output-format", "mp4/mkv"]
        switch (quality, ffmpegPath != nil) {
        case (.audio, true): return ["-f", "ba/b", "-x", "--audio-format", "m4a"]
        case (.audio, false): return ["-f", "ba[ext=m4a]/ba/b"]
        case (.best, true): return ["-f", "bv*+ba/b"] + sorting
        case (.best, false): return ["-f", "b"]
        case (_, true):
            let height = quality.maxHeight ?? 0
            return ["-f", "bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"] + sorting
        case (_, false):
            let height = quality.maxHeight ?? 0
            return ["-f", "b[height<=\(height)]/b"]
        }
    }

    /// Everything yt-dlp is started with. Its progress, the video title and the finished file come back as
    /// lines starting with "[cdl]", "[cdl-title]" and "[cdl-file]" (see `YtDlpProgress`).
    public static func arguments(
        url: URL, quality: VideoQuality, workFolder: URL, ffmpegPath: String?, speedLimit: Int64?,
        cookiesFile: URL?, cookiesFromBrowser: String?
    ) -> [String] {
        var arguments = [
            "--ignore-config", "--no-playlist", "--newline", "--progress", "--color", "never",
            "--progress-template", "download:[cdl] %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
            "--print", "before_dl:[cdl-title] %(title)s",
            "--print", "after_move:[cdl-file] %(filepath)s",
            "-P", workFolder.path, "-o", "%(title).150B.%(ext)s",
        ]
        arguments += formatArguments(quality: quality, ffmpegPath: ffmpegPath)
        if let ffmpegPath { arguments += ["--ffmpeg-location", ffmpegPath] }
        if let speedLimit { arguments += ["--limit-rate", String(speedLimit)] }
        arguments += cookieArguments(file: cookiesFile, browser: cookiesFromBrowser)
        return arguments + ["--", url.absoluteString]
    }

    /// A cookie file made from the browser's sign-in wins over reading a browser's cookies directly.
    static func cookieArguments(file: URL?, browser: String?) -> [String] {
        if let file { return ["--cookies", file.path] }
        if let browser, !browser.isEmpty { return ["--cookies-from-browser", browser] }
        return []
    }

    /// The search path yt-dlp runs with: its own folder, the tools packed inside the app, and Homebrew's first, so
    /// it finds deno and ffmpeg even when the app was opened from Finder, which only passes the system folders.
    public static func searchPath(executable: String, inherited: String?, bundled: String? = AppPaths.bundledToolsDirectory?.path) -> String {
        let own = (executable as NSString).deletingLastPathComponent
        let inheritedFolders = (inherited ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return ([own, bundled ?? ""] + toolFolders + inheritedFolders)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// Runs work that waits on yt-dlp for as long as it runs. It gets a thread of its own: the shared worker
    /// threads are few, and the app's other downloads need them, so they must never sit waiting on a tool.
    static func onOwnThread(_ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.name = "yt-dlp"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Asks a running tool to stop: an interrupt first (yt-dlp then keeps its partial file), then terminate,
    /// then kill, each after `grace` seconds, so a tool that ignores the polite requests still ends.
    static func stop(_ process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Deletes YouTube sign-in files left in the work folders by a quit or a crash, and old playlist listings.
    /// Partial downloads stay, so they can be resumed.
    public static func removeLeftoverSignIns(in temporaryDirectory: URL) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if folder.pathExtension == "ytdlp" {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("cookies.txt"))
            } else if folder.lastPathComponent.hasPrefix("playlist-") {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Runs yt-dlp to the end on a background thread and returns its exit code and output. With a time limit,
    /// a run that takes longer is stopped and reported as timed out.
    static func run(
        _ executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval? = nil, stopGrace: TimeInterval = 5
    ) async throws -> (status: Int32, output: String, errors: String, timedOut: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            onOwnThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var environment = environment
                environment["PATH"] = searchPath(executable: executable, inherited: environment["PATH"])
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timedOut = LockedFlag()
                let timer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    stop(process, grace: stopGrace)
                }
                if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
                let errorText = ErrorCollector()
                let collected = DispatchGroup()
                collected.enter()
                onOwnThread {
                    errorText.store(errors.fileHandleForReading.readDataToEndOfFile())
                    collected.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                collected.wait()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self), errorText.text, timedOut.isSet))
            }
        }
    }

    /// A short reason for a failed run, taken from yt-dlp's last error line.
    public static func failureMessage(stderr: String, exitCode: Int32) -> String {
        if stderr.contains("not a bot") { return botCheckMessage }
        let fallback = "yt-dlp stopped (code \(exitCode))"
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let last = lines.last(where: { $0.hasPrefix("ERROR:") }) else { return fallback }
        var text = last.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
        // "[youtube] dQw4w9WgXcQ: Video unavailable" -> "Video unavailable"
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if let colon = text.range(of: ": "), !text[..<colon.lowerBound].contains(" ") {
                text = String(text[colon.upperBound...])
            }
        }
        return text.isEmpty ? fallback : text
    }

    /// A cookie file in the format yt-dlp reads, made from the Cookie header the browser add-on sent with a
    /// YouTube address. Pairs that could break the file's lines are left out. Nil when nothing usable is left.
    public static func cookieFile(header: String?) -> String? {
        guard let header else { return nil }
        var lines: [String] = []
        for pair in header.split(separator: ";") {
            let piece = pair.trimmingCharacters(in: .whitespaces)
            guard !piece.contains(where: { $0 == "\t" || $0.isNewline }), let equals = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            lines.append(".youtube.com\tTRUE\t/\tTRUE\t4102444800\t\(name)\t\(piece[piece.index(after: equals)...])")
        }
        guard !lines.isEmpty else { return nil }
        return (["# Netscape HTTP Cookie File"] + lines).joined(separator: "\n") + "\n"
    }
}

/// Reads yt-dlp's output lines. A best-quality download fetches the picture and then the sound as two
/// parts, each counting from zero; the parts are added up so the progress keeps growing.
public struct YtDlpProgress: Sendable {
    public struct Update: Sendable, Equatable {
        public var downloadedBytes: Int64
        public var totalBytes: Int64?
        /// 0 when yt-dlp does not know the speed yet.
        public var bytesPerSecond: Double

        public init(downloadedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Double) {
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
            self.bytesPerSecond = bytesPerSecond
        }
    }

    private var finishedParts: Int64 = 0
    private var currentPart: Int64 = 0

    public init() {}

    /// The progress after a "[cdl] downloaded total estimate speed" line; nil for any other line.
    public mutating func consume(_ line: String) -> Update? {
        guard line.hasPrefix("[cdl] ") else { return nil }
        let fields = line.dropFirst("[cdl] ".count).split(separator: " ")
        guard fields.count == 4, let downloaded = Self.number(fields[0]) else { return nil }
        let current = Int64(downloaded.rounded())
        if current < currentPart { finishedParts += currentPart }
        currentPart = current
        let total = Self.number(fields[1]) ?? Self.number(fields[2])
        return Update(
            downloadedBytes: finishedParts + current,
            totalBytes: total.map { finishedParts + Int64($0.rounded()) },
            bytesPerSecond: Self.number(fields[3]) ?? 0
        )
    }

    public static func title(from line: String) -> String? { value(of: "[cdl-title] ", in: line) }
    public static func file(from line: String) -> String? { value(of: "[cdl-file] ", in: line) }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// yt-dlp prints "NA" for values it does not know.
    private static func number(_ text: Substring) -> Double? {
        guard let value = Double(text), value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// The videos of a YouTube playlist, read with yt-dlp's quick listing (no video is downloaded).
public enum YtDlpPlaylist {
    public struct Failure: Error, Sendable {
        public var message: String
    }

    /// Lists the playlist's videos. The YouTube sign-in goes in a cookie file that only the user can read
    /// and that is deleted as soon as the listing ends.
    public static func expand(
        url: URL, executable: String, cookiesHeader: String?, browser: String?, temporaryDirectory: URL, environment: [String: String],
        timeout: TimeInterval = 60, stopGrace: TimeInterval = 5
    ) async throws -> [Entry] {
        let folder = temporaryDirectory.appendingPathComponent("playlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cookiesFile: URL?
        if let text = YtDlp.cookieFile(header: cookiesHeader) {
            let file = folder.appendingPathComponent("cookies.txt")
            if FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) {
                cookiesFile = file
            }
        }
        let arguments = ["--ignore-config", "--flat-playlist", "--print", "%(id)s\t%(title)s"]
            + YtDlp.cookieArguments(file: cookiesFile, browser: browser) + ["--", url.absoluteString]
        let result = try await YtDlp.run(executable, arguments: arguments, environment: environment, timeout: timeout, stopGrace: stopGrace)
        if result.timedOut { throw Failure(message: "Reading the playlist took too long.") }
        guard result.status == 0 else {
            throw Failure(message: YtDlp.failureMessage(stderr: result.errors, exitCode: result.status))
        }
        return parseFlat(result.output)
    }

    public struct Entry: Sendable, Equatable {
        public var id: String
        /// Empty when yt-dlp does not know it.
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    private static let unavailableTitles: Set<String> = ["[Private video]", "[Deleted video]"]

    /// Reads "ID<tab>title" lines. Private and deleted videos and repeated IDs are left out; order is kept.
    public static func parseFlat(_ output: String) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            var title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard YouTubeLinks.isVideoID(id), !unavailableTitles.contains(title), !seen.contains(id) else { continue }
            if title == "NA" { title = "" }
            seen.insert(id)
            entries.append(Entry(id: id, title: title))
        }
        return entries
    }
}

/// yt-dlp's error output, filled from another thread; only the last 64 KB are kept.
final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.withLock { data = value.suffix(65_536) }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// A yes/no set from another thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
