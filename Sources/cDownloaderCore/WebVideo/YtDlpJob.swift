import Foundation

/// Downloads a YouTube video by running yt-dlp in a work folder of its own, then moves the finished file
/// into the download folder. Pausing stops yt-dlp; its partial file stays in the work folder and the next
/// start continues it. The YouTube sign-in from the browser add-on is handed over in a cookie file that only
/// the user can read and that is deleted as soon as yt-dlp stops.
public final class YtDlpJob: DownloadRunner, @unchecked Sendable {
    public let id: UUID
    private let engine: DownloadEngine
    private let configuration: EngineConfiguration
    private let onEvent: @Sendable (DownloadJob.Event) -> Void
    private let lock = NSLock()
    private var state: DownloadItem
    private var process: Process?
    private var running = false
    private var pauseRequested = false
    private var stopSent = false
    /// Test hook: runs after the process is set up and just before it starts.
    var beforeLaunch: (@Sendable () -> Void)?

    /// Extensions a typed name may end with; anything else after a dot is part of the name ("Ep. 3").
    private static let mediaExtensions: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v", "m4a", "mp3", "opus", "ogg", "aac", "wav", "flac"]

    init(item: DownloadItem, engine: DownloadEngine, configuration: EngineConfiguration, onEvent: @escaping @Sendable (DownloadJob.Event) -> Void) {
        self.id = item.id
        self.state = item
        self.engine = engine
        self.configuration = configuration
        self.onEvent = onEvent
    }

    public var item: DownloadItem { lock.withLock { state } }

    private var workFolder: URL {
        configuration.temporaryDirectory.appendingPathComponent("\(id.uuidString).ytdlp", isDirectory: true)
    }

    private var cookieFileURL: URL { workFolder.appendingPathComponent("cookies.txt") }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !running, state.status != .completed else { return false }
            running = true
            pauseRequested = false
            stopSent = false
            state.status = .downloading
            state.errorMessage = nil
            state.lastTry = engine.clock.now
            return true
        }
        guard shouldStart else { return }
        YtDlp.onOwnThread { [self] in run() }
    }

    public func pause() {
        let current = lock.withLock { () -> Process? in
            pauseRequested = true
            return process
        }
        // A process that is set up but not started yet is stopped by run() right after it starts.
        if let current, current.isRunning { stopIfRequested(current) }
    }

    /// Sends the stop request once, whichever of pause() and run() sees the running process first.
    private func stopIfRequested(_ process: Process) {
        let send = lock.withLock { () -> Bool in
            guard pauseRequested, !stopSent else { return false }
            stopSent = true
            return true
        }
        if send { YtDlp.stop(process, grace: configuration.toolStopGrace) }
    }

    // MARK: - Run

    private func run() {
        let current = item
        // Looked up again when not found at launch, so installing yt-dlp works without restarting the app.
        guard let tool = configuration.ytDlpPath ?? YtDlp.locate(), FileManager.default.isExecutableFile(atPath: tool) else {
            return failed(YtDlp.missingMessage)
        }
        let link = YouTubeLinks.classify(current.url)
        if case .playlist = link { return failed(YtDlp.playlistMessage) }
        var quality = VideoQuality.best
        if case .webVideo(let chosen) = current.kind { quality = chosen }

        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        } catch {
            return failed("Cannot create the work folder: \(error.localizedDescription)")
        }
        // The sign-in only ever goes to YouTube itself.
        var cookiesFile: URL?
        if link != nil, let text = YtDlp.cookieFile(header: current.cookies) {
            try? FileManager.default.removeItem(at: cookieFileURL)
            if FileManager.default.createFile(atPath: cookieFileURL.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) {
                cookiesFile = cookieFileURL
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = YtDlp.arguments(
            url: current.url, quality: quality, workFolder: workFolder, ffmpegPath: configuration.ffmpegPath,
            speedLimit: [current.speedLimit, engine.limiter.globalLimit].compactMap { $0 }.filter { $0 > 0 }.min(),
            cookiesFile: cookiesFile, cookiesFromBrowser: configuration.ytDlpCookiesBrowser
        )
        var environment = configuration.toolEnvironment
        environment["PATH"] = YtDlp.searchPath(executable: tool, inherited: environment["PATH"])
        process.environment = environment
        process.currentDirectoryURL = workFolder
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let pausedBeforeLaunch = lock.withLock { () -> Bool in
            if pauseRequested { return true }
            self.process = process
            return false
        }
        if pausedBeforeLaunch {
            removeCookieFile()
            return stopped()
        }
        beforeLaunch?()
        do {
            try process.run()
        } catch {
            lock.withLock { self.process = nil }
            removeCookieFile()
            return failed("yt-dlp could not be started: \(error.localizedDescription)")
        }
        stopIfRequested(process)
        publish(.started(item))

        // Error lines are collected on the side, so a chatty yt-dlp never blocks on a full pipe.
        let errorText = ErrorCollector()
        let collected = DispatchGroup()
        collected.enter()
        YtDlp.onOwnThread {
            errorText.store(errors.fileHandleForReading.readDataToEndOfFile())
            collected.leave()
        }
        let finishedFile = readOutput(output.fileHandleForReading)
        process.waitUntilExit()
        collected.wait()
        removeCookieFile()
        let paused = lock.withLock { () -> Bool in
            self.process = nil
            return pauseRequested
        }

        if process.terminationStatus != 0 {
            return paused ? stopped() : failed(YtDlp.failureMessage(stderr: errorText.text, exitCode: process.terminationStatus))
        }
        let reported = finishedFile.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let file = reported ?? largestFinishedFile() else { return failed(YtDlp.noFileMessage) }
        do {
            try complete(with: file)
        } catch {
            failed("Cannot move the finished file: \(error.localizedDescription)")
        }
    }

    /// Reads yt-dlp's output line by line until it ends; returns the finished file it reported, if any.
    private func readOutput(_ handle: FileHandle) -> String? {
        var progress = YtDlpProgress()
        var finishedFile: String?
        var buffer = Data()
        func handleLine(_ data: Data) {
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let update = progress.consume(line) {
                let snapshot = lock.withLock { () -> DownloadProgressSnapshot in
                    state.downloadedBytes = update.downloadedBytes
                    state.totalBytes = update.totalBytes
                    return DownloadProgressSnapshot(
                        id: id, downloadedBytes: update.downloadedBytes, totalBytes: update.totalBytes,
                        bytesPerSecond: update.bytesPerSecond, activeConnections: 1, resumable: true,
                        segments: SegmentProgress(bars: [], downloadedBytes: update.downloadedBytes, totalBytes: update.totalBytes ?? 0)
                    )
                }
                publish(.progress(snapshot))
            } else if let title = YtDlpProgress.title(from: line) {
                lock.withLock {
                    if state.fileName.isEmpty { state.fileName = FileNameResolver.sanitize(title) }
                }
            } else if let file = YtDlpProgress.file(from: line) {
                finishedFile = file
            }
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                handleLine(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            // A line this long is not one of the lines read here; it is dropped instead of kept in memory.
            if buffer.count > 1_000_000 { buffer.removeAll() }
        }
        if !buffer.isEmpty { handleLine(buffer) }
        return finishedFile
    }

    /// When yt-dlp did not say which file it made (for example "already downloaded"), the largest finished file.
    private func largestFinishedFile() -> URL? {
        let skipped = ["part", "ytdl", "temp"]
        let files = (try? FileManager.default.contentsOfDirectory(at: workFolder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        return files
            .filter { $0.lastPathComponent != cookieFileURL.lastPathComponent && !skipped.contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .max { Self.fileSize($0) < Self.fileSize($1) }
    }

    private func complete(with file: URL) throws {
        let current = item
        let folder = URL(fileURLWithPath: current.directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = file.pathExtension
        let base = Self.baseName(current.fileName, downloadedExtension: ext) ?? file.deletingPathExtension().lastPathComponent
        let destination = FileNameResolver.uniqueURL(for: folder.appendingPathComponent(ext.isEmpty ? base : base + "." + ext))
        try FileManager.default.moveItem(at: file, to: destination)
        try? FileManager.default.removeItem(at: workFolder)
        let size = Self.fileSize(destination)
        let finished = lock.withLock { () -> DownloadItem in
            running = false
            state.fileName = destination.lastPathComponent
            state.status = .completed
            state.totalBytes = size
            state.downloadedBytes = size
            state.dateCompleted = engine.clock.now
            return state
        }
        publish(.completed(finished))
    }

    /// The name to save under: the typed or title-based name without a media extension, cleaned again.
    static func baseName(_ name: String, downloadedExtension: String) -> String? {
        var base = name
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext == downloadedExtension.lowercased() || mediaExtensions.contains(ext) {
            base = (name as NSString).deletingPathExtension
        }
        let clean = FileNameResolver.sanitize(base)
        return clean.isEmpty ? nil : clean
    }

    private func removeCookieFile() {
        try? FileManager.default.removeItem(at: cookieFileURL)
    }

    private func stopped() {
        let paused = lock.withLock { () -> DownloadItem in
            running = false
            state.status = .stopped
            return state
        }
        publish(.paused(paused))
    }

    private func failed(_ message: String) {
        let failedItem = lock.withLock { () -> DownloadItem in
            running = false
            state.status = .failed
            state.errorMessage = message
            return state
        }
        publish(.failed(failedItem))
    }

    private func publish(_ event: DownloadJob.Event) {
        onEvent(event)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
