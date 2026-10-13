import CommonCrypto
import Foundation

/// Downloads an HLS stream: fetches the playlist, downloads pieces in parallel,
/// decrypts AES-128 pieces and joins them in order into one file.
/// Finished pieces are kept on pause, so a resumed download skips them.
public final class HLSJob: DownloadRunner, @unchecked Sendable {
    public let id: UUID
    private let engine: DownloadEngine
    private let configuration: EngineConfiguration
    private let onEvent: @Sendable (DownloadJob.Event) -> Void
    private let session: URLSession
    private let lock = NSLock()
    private var state: DownloadItem
    private var task: Task<Void, Never>?
    private var running = false
    private var piecesDone = 0
    private var pieceCount = 0
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    private var lastProgress = Date.distantPast

    init(item: DownloadItem, engine: DownloadEngine, configuration: EngineConfiguration, onEvent: @escaping @Sendable (DownloadJob.Event) -> Void) {
        self.id = item.id
        self.state = item
        self.engine = engine
        self.configuration = configuration
        self.onEvent = onEvent
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.httpMaximumConnectionsPerHost = 16
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.connectionProxyDictionary = ProxyConfigurator.connectionProxyDictionary(for: configuration.proxy)
        self.session = URLSession(configuration: sessionConfiguration)
    }

    deinit { session.invalidateAndCancel() }

    public var item: DownloadItem { lock.withLock { state } }

    private var workFolder: URL {
        configuration.temporaryDirectory.appendingPathComponent("\(id.uuidString).hls", isDirectory: true)
    }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !running, state.status != .completed else { return false }
            running = true
            state.status = .downloading
            state.errorMessage = nil
            state.lastTry = engine.clock.now
            return true
        }
        guard shouldStart else { return }
        task = Task { [self] in await run() }
    }

    public func pause() {
        task?.cancel()
    }

    // MARK: - Run

    /// One track of the stream: the video (which may carry sound) or a separate sound track.
    private struct Track {
        var playlist: HLSMediaPlaylist
        var prefix: String
        var pieces: [HLSSegment] { (playlist.initSegment.map { [$0] } ?? []) + playlist.segments }
    }

    private func run() async {
        do {
            let (video, audio) = try await loadPlaylists()
            let tracks = [Track(playlist: video, prefix: "v")] + (audio.map { [Track(playlist: $0, prefix: "a")] } ?? [])
            let pieces = tracks.flatMap { track in track.pieces.enumerated().map { (track.prefix, $0.offset, $0.element) } }
            let keys = try await loadKeys(for: pieces.map(\.2))
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            let files = pieces.map { workFolder.appendingPathComponent(String(format: "%@%05d.seg", $0.0, $0.1)) }
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            lock.withLock {
                pieceCount = pieces.count
                piecesDone = existing.count
                state.downloadedBytes = existing.reduce(0) { $0 + Self.fileSize($1) }
            }
            publish(.started(item))

            let limit = max(1, min(configuration.maxConnections, 8))
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func addNext() {
                    while next < pieces.count, FileManager.default.fileExists(atPath: files[next].path) { next += 1 }
                    guard next < pieces.count else { return }
                    let index = next
                    next += 1
                    let piece = pieces[index].2
                    group.addTask { [self] in
                        try await downloadPiece(piece, key: piece.key.flatMap { $0.uri }.flatMap { keys[$0] }, to: files[index])
                    }
                }
                for _ in 0..<limit { addNext() }
                while try await group.next() != nil { addNext() }
            }
            try Task.checkCancellation()
            let videoFiles = zip(pieces, files).filter { $0.0.0 == "v" }.map(\.1)
            let audioFiles = zip(pieces, files).filter { $0.0.0 == "a" }.map(\.1)
            try await finish(video: video, videoFiles: videoFiles, audio: audio, audioFiles: audioFiles)
        } catch is CancellationError {
            stopped()
        } catch {
            if Task.isCancelled { return stopped() }
            let message = (error as? HLSError)?.message ?? (error as? DownloadFailure)?.message ?? error.localizedDescription
            failed(message)
        }
    }

    /// The video playlist, plus the separate sound track when the stream keeps sound apart.
    private func loadPlaylists() async throws -> (HLSMediaPlaylist, HLSMediaPlaylist?) {
        var url = item.url
        var playlist = try HLSParser.parse(try await text(at: url), baseURL: url)
        var audio: HLSMediaPlaylist?
        if case .master(let variants) = playlist {
            var index: Int?
            if case .hls(let chosen) = item.kind { index = chosen }
            guard let variant = HLSParser.select(variants, index: index) else { throw HLSError.noVariants }
            url = variant.url
            playlist = try HLSParser.parse(try await text(at: url), baseURL: url)
            if let track = variant.audio {
                guard case .media(let sound) = try HLSParser.parse(try await text(at: track.url), baseURL: track.url) else { throw HLSError.notAPlaylist }
                audio = sound
            }
        }
        guard case .media(let media) = playlist else { throw HLSError.notAPlaylist }
        lock.withLock {
            state.finalURL = url
            // A playlist's own name ("index.m3u8") is not a video name: keep the base, the extension comes at the end.
            var base = (state.fileName as NSString).deletingPathExtension
            if base.isEmpty { base = ((state.url.lastPathComponent as NSString).deletingPathExtension) }
            if base.isEmpty || base == "/" { base = "video" }
            state.fileName = FileNameResolver.sanitize(base) + "." + Self.videoExtension(media)
        }
        return (media, audio)
    }

    private static func videoExtension(_ playlist: HLSMediaPlaylist) -> String {
        playlist.initSegment != nil ? "mp4" : "ts"
    }

    private static func audioExtension(_ playlist: HLSMediaPlaylist) -> String {
        if playlist.initSegment != nil { return "m4a" }
        let ext = playlist.segments.first?.url.pathExtension.lowercased() ?? ""
        return ["aac", "mp3", "ac3", "ec3"].contains(ext) ? ext : "ts"
    }

    private func text(at url: URL) async throws -> String {
        do {
            return String(decoding: try await fetch(url, range: nil), as: UTF8.self)
        } catch HLSError.segmentFailed(let reason) {
            throw HLSError.playlistFailed(reason)
        }
    }

    private func loadKeys(for pieces: [HLSSegment]) async throws -> [URL: Data] {
        var keys: [URL: Data] = [:]
        for uri in Set(pieces.compactMap { $0.key?.uri }) {
            let data: Data
            do {
                data = try await fetch(uri, range: nil)
            } catch {
                throw HLSError.keyFailed((error as? DownloadFailure)?.message ?? error.localizedDescription)
            }
            guard data.count == 16 else { throw HLSError.keyFailed("the key is \(data.count) bytes instead of 16") }
            keys[uri] = data
        }
        return keys
    }

    private func downloadPiece(_ piece: HLSSegment, key: Data?, to file: URL) async throws {
        var data = try await fetch(piece.url, range: piece.byteRange)
        if piece.key != nil {
            guard let key else { throw HLSError.keyFailed("missing key") }
            data = try Self.decrypt(data, key: key, iv: piece.effectiveIV)
        }
        try data.write(to: file, options: .atomic)
        let snapshot = lock.withLock { () -> DownloadProgressSnapshot in
            piecesDone += 1
            state.downloadedBytes += Int64(data.count)
            let now = Date()
            speedSamples.append((now, state.downloadedBytes))
            speedSamples.removeAll { now.timeIntervalSince($0.time) > 4 }
            return progressSnapshot()
        }
        publish(.progress(snapshot))
    }

    /// GET with retries for network errors and server overload; a missing file is not retried.
    private func fetch(_ url: URL, range: ClosedRange<Int64>?) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            let current = item
            request.setValue(current.userAgent ?? configuration.userAgent, forHTTPHeaderField: "User-Agent")
            if let referer = current.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
            if let cookies = current.cookies, current.url.sharesCredentials(with: url) { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
            var failure: DownloadFailure
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if status == 200 || status == 206 {
                    if let range, status == 200, data.count > Int(range.upperBound) {
                        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
                    }
                    return data
                }
                failure = status == 401 ? .authenticationRequired : .http(status)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = .network(error.localizedDescription)
            }
            attempt += 1
            guard failure.isRetryable, attempt <= configuration.retriesPerConnection else {
                throw HLSError.segmentFailed(failure.message)
            }
            try await Task.sleep(for: .seconds(configuration.retryDelay * Double(attempt)))
        }
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSError.keyFailed("decryption failed (\(status))") }
        return out.prefix(moved)
    }

    // MARK: - Finish

    /// Joins the pieces in order. A separate sound track is combined with the video by ffmpeg into one .mp4;
    /// without ffmpeg it is saved next to the video. With ffmpeg, a .ts video also becomes an .mp4.
    private func finish(video: HLSMediaPlaylist, videoFiles: [URL], audio: HLSMediaPlaylist?, audioFiles: [URL]) async throws {
        let videoJoined = workFolder.appendingPathComponent("joined.\(Self.videoExtension(video))")
        try Self.join(videoFiles, into: videoJoined)
        var soundJoined: URL?
        if let audio {
            let file = workFolder.appendingPathComponent("joined-audio.\(Self.audioExtension(audio))")
            try Self.join(audioFiles, into: file)
            soundJoined = file
        }

        let current = item
        let folder = URL(fileURLWithPath: current.directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (current.fileName as NSString).deletingPathExtension
        var result = videoJoined
        var note: String?
        if let ffmpeg = configuration.ffmpegPath, soundJoined != nil || videoJoined.pathExtension == "ts" {
            let combined = workFolder.appendingPathComponent("combined.mp4")
            if await Self.combine(ffmpeg: ffmpeg, video: videoJoined, audio: soundJoined, output: combined) {
                result = combined
                soundJoined = nil
            }
        }
        let destination = FileNameResolver.uniqueURL(for: folder.appendingPathComponent(base + "." + result.pathExtension))
        try FileManager.default.moveItem(at: result, to: destination)
        if let soundJoined {
            let soundName = destination.deletingPathExtension().lastPathComponent + ".audio." + soundJoined.pathExtension
            let soundFile = FileNameResolver.uniqueURL(for: folder.appendingPathComponent(soundName))
            try FileManager.default.moveItem(at: soundJoined, to: soundFile)
            note = "The sound was saved separately as \(soundFile.lastPathComponent). Install ffmpeg to get one file with sound."
        }
        try? FileManager.default.removeItem(at: workFolder)
        let total = Self.fileSize(destination)
        let finished = lock.withLock { () -> DownloadItem in
            running = false
            state.fileName = destination.lastPathComponent
            state.status = .completed
            state.totalBytes = total
            state.downloadedBytes = total
            state.dateCompleted = engine.clock.now
            if let note { state.descriptionText = state.descriptionText.isEmpty ? note : state.descriptionText + " " + note }
            return state
        }
        publish(.completed(finished))
    }

    private static func join(_ files: [URL], into output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for file in files {
            try handle.write(contentsOf: try Data(contentsOf: file))
        }
    }

    /// Copies the video (and the separate sound, when given) into one .mp4 without re-encoding.
    private static func combine(ffmpeg: String, video: URL, audio: URL?, output: URL) async -> Bool {
        var arguments = ["-v", "error", "-y", "-i", video.path]
        if let audio { arguments += ["-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"] }
        arguments += ["-c", "copy"]
        let adts = audio.map { ["ts", "aac"].contains($0.pathExtension) } ?? (video.pathExtension == "ts")
        if adts { arguments += ["-bsf:a", "aac_adtstoasc"] }
        arguments += ["-movflags", "+faststart", output.path]
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path))
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
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

    private func progressSnapshot() -> DownloadProgressSnapshot {
        var speed = 0.0
        if let first = speedSamples.first, let last = speedSamples.last, last.time > first.time {
            speed = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        }
        let count = max(1, pieceCount)
        let bars = (0..<pieceCount).map { index in
            SegmentProgress.Bar(
                startFraction: Double(index) / Double(count),
                downloadedEndFraction: Double(index + (index < piecesDone ? 1 : 0)) / Double(count),
                endFraction: Double(index + 1) / Double(count),
                downloadedBytes: 0,
                remainingBytes: 0,
                isActive: false
            )
        }
        return DownloadProgressSnapshot(
            id: id,
            downloadedBytes: state.downloadedBytes,
            totalBytes: nil,
            bytesPerSecond: speed,
            activeConnections: min(configuration.maxConnections, max(0, pieceCount - piecesDone)),
            resumable: true,
            segments: SegmentProgress(bars: bars, downloadedBytes: state.downloadedBytes, totalBytes: 0)
        )
    }

    private func publish(_ event: DownloadJob.Event) {
        onEvent(event)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
