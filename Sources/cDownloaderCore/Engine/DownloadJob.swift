import Foundation

/// Downloads one item with several connections; all state changes happen on `queue`.
///
/// The first connection asks for `bytes=0-`. Its answer tells whether the server supports ranges
/// and how large the file is. When it does, more connections are opened, each taking the second half
/// of the piece with the most bytes left (see `SegmentPlanner`). Every connection reads an open-ended
/// range and is stopped once it reaches the end of its piece.
public final class DownloadJob: DownloadRunner, TransferConnectionDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        case started(DownloadItem)
        case progress(DownloadProgressSnapshot)
        /// Positions were saved to disk; persist this item.
        case checkpoint(DownloadItem)
        case paused(DownloadItem)
        case completed(DownloadItem)
        case failed(DownloadItem)
    }

    private final class Link: @unchecked Sendable {
        let connection: TransferConnection
        var segmentID: Int?
        var offset: Int64
        /// The first request of a run; its response decides how the file is split.
        var isProbe: Bool
        /// While throttled: when reading may continue. Only ever moves later.
        var resumeAt: Date?
        /// URLSession counts suspends, so the connection is suspended at most once at a time.
        var isSuspended = false
        /// Data that arrived while throttled, written once the pause is over.
        var pending: [Data] = []
        /// The connection ended while data was still waiting; `.some(nil)` means it ended cleanly.
        var pendingCompletion: DownloadFailure??

        init(connection: TransferConnection, segmentID: Int?, offset: Int64, isProbe: Bool) {
            self.connection = connection
            self.segmentID = segmentID
            self.offset = offset
            self.isProbe = isProbe
        }
    }

    public let id: UUID
    let queue: DispatchQueue
    private let engine: DownloadEngine
    private let configuration: EngineConfiguration
    private let onEvent: @Sendable (Event) -> Void

    // Confined to `queue`.
    private var state: DownloadItem
    private var planner: SegmentPlanner?
    private var writer: FileWriter?
    private var running = false
    private var links: [ObjectIdentifier: Link] = [:]
    private var retries: [Int: Int] = [:]
    private var runURL: URL?
    private var validator: String?
    private var connectionCap = 1
    private var restartedThisRun = false
    private var probeRangeRetried = false
    private var lastCheckpoint = Date.distantPast
    private var lastProgress = Date.distantPast
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    /// Most connections open at once during this job (for tests of the connection limit).
    private var mostLinks = 0

    private let snapshotLock = NSLock()
    private var snapshot: DownloadItem

    private static let probeKey = -1

    init(item: DownloadItem, engine: DownloadEngine, configuration: EngineConfiguration, onEvent: @escaping @Sendable (Event) -> Void) {
        self.id = item.id
        self.state = item
        self.snapshot = item
        self.engine = engine
        self.configuration = configuration
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "DownloadJob.\(item.id.uuidString)")
    }

    /// The item as of the last event.
    public var item: DownloadItem { snapshotLock.withLock { snapshot } }

    public var temporaryFileURL: URL {
        configuration.temporaryDirectory.appendingPathComponent("\(id.uuidString).part")
    }

    public var isRunning: Bool { queue.sync { running } }

    // MARK: - Control

    public func start() {
        queue.async { [self] in
            guard !running, state.status != .completed else { return }
            running = true
            restartedThisRun = false
            probeRangeRetried = false
            retries = [:]
            runURL = nil
            state.status = .downloading
            state.errorMessage = nil
            state.lastTry = engine.clock.now
            let host = state.url.host ?? ""
            connectionCap = ConnectionLimits.maxConnections(
                forHost: host,
                exceptions: configuration.connectionExceptions,
                defaultValue: state.maxConnections ?? configuration.maxConnections
            )
            engine.limiter.setLimit(state.speedLimit, for: id)
            writer = FileWriter(url: temporaryFileURL)
            validator = configuration.ignoreModificationTimeChanges ? nil : (state.etag ?? state.lastModified)

            let hasPartialFile = FileManager.default.fileExists(atPath: temporaryFileURL.path)
            if state.resumable, let total = state.totalBytes, !state.segments.isEmpty, hasPartialFile {
                planner = SegmentPlanner(restoring: state.segments, totalSize: total, minSegmentSize: configuration.minSegmentSize)
                do {
                    try writer?.open(truncate: false)
                    try writer?.setLength(total)
                } catch {
                    return fail(error as? DownloadFailure ?? .fileSystem(error.localizedDescription))
                }
                state.downloadedBytes = planner?.downloadedBytes ?? 0
                publish(.started(state))
                if planner?.isComplete == true { return finish() }
                fillSlots()
            } else {
                // Fresh start, or a server without range support: begin again from byte 0.
                let useRange = state.downloadedBytes == 0 || state.resumable
                resetProgress()
                do { try writer?.open(truncate: true) } catch {
                    return fail(error as? DownloadFailure ?? .fileSystem(error.localizedDescription))
                }
                openProbe(useRange: useRange)
            }
        }
    }

    public func pause() {
        queue.async { [self] in
            guard running else { return }
            stopAllLinks()
            running = false
            writer?.sync()
            writer?.close()
            state.status = .stopped
            saveProgressIntoState()
            publish(.paused(state))
        }
    }

    /// Highest number of connections this job had open at the same time.
    var peakConnections: Int { queue.sync { mostLinks } }

    /// Simulates a crash: drops all connections without saving anything.
    func abandonForTesting() {
        queue.sync {
            running = false
            stopAllLinks()
            writer?.close()
        }
    }

    // MARK: - Connections

    private func resetProgress() {
        planner = nil
        state.segments = []
        state.downloadedBytes = 0
        state.totalBytes = nil
        state.resumable = false
        speedSamples = []
    }

    private func makeRequest(offset: Int64, useRange: Bool) -> TransferRequest {
        let target = runURL ?? state.url
        // After a redirect to another site, the browser's cookies and the login stay behind.
        let ownSite = state.url.sharesCredentials(with: target)
        var headers = state.extraHeaders
        headers["User-Agent"] = state.userAgent ?? configuration.userAgent
        if let referer = state.referer, !referer.isEmpty { headers["Referer"] = referer }
        if ownSite, let cookies = state.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        let credentials = ownSite
            ? SiteLoginResolver.credentials(for: state, logins: configuration.siteLogins, secrets: engine.secrets).map { Credentials(user: $0.user, password: $0.password) }
            : nil
        return TransferRequest(
            url: target,
            headers: headers,
            credentials: credentials,
            validator: offset > 0 ? validator : nil,
            offset: offset,
            useRange: useRange
        )
    }

    @discardableResult
    private func openLink(offset: Int64, segmentID: Int?, isProbe: Bool, useRange: Bool) -> Bool {
        let request = makeRequest(offset: offset, useRange: useRange)
        guard let transport = engine.transport(for: request.url) else {
            fail(.unsupported("Unsupported address type: \(request.url.scheme ?? "none")"))
            return false
        }
        let connection = transport.open(request, delegate: self, queue: queue)
        links[ObjectIdentifier(connection)] = Link(connection: connection, segmentID: segmentID, offset: offset, isProbe: isProbe)
        mostLinks = max(mostLinks, links.count)
        return true
    }

    private func openProbe(useRange: Bool) {
        openLink(offset: 0, segmentID: nil, isProbe: true, useRange: useRange)
    }

    /// Gives every free connection slot a piece of the file.
    private func fillSlots() {
        guard running, state.resumable, planner?.totalSize != nil else { return }
        while links.count < connectionCap, let segment = planner?.assign() {
            guard openLink(offset: segment.position, segmentID: segment.id, isProbe: false, useRange: true) else { return }
        }
    }

    private func stopAllLinks() {
        let all = links.values
        links.removeAll()
        for link in all {
            link.connection.cancel()
            if let segment = link.segmentID { planner?.release(segment) }
        }
    }

    private func drop(_ link: Link) {
        links.removeValue(forKey: ObjectIdentifier(link.connection))
        link.connection.cancel()
        if let segment = link.segmentID { planner?.release(segment) }
    }

    private func link(for connection: TransferConnection) -> Link? {
        running ? links[ObjectIdentifier(connection)] : nil
    }

    // MARK: - TransferConnectionDelegate

    public func connection(_ connection: TransferConnection, didReceive response: TransferResponse) {
        guard let link = link(for: connection) else { return }
        if let code = response.statusCode, !(200...299).contains(code) {
            if code == 416, link.isProbe, !probeRangeRetried {
                // Some servers refuse "bytes=0-" for an empty file; ask again without a range.
                probeRangeRetried = true
                drop(link)
                return openProbe(useRange: false)
            }
            if code == 416, link.offset > 0, !restartedThisRun {
                return restart(keeping: nil)
            }
            return linkFailed(link, code == 401 ? .authenticationRequired : .http(code))
        }
        if link.isProbe {
            return adoptProbe(link, response)
        }
        if response.statusCode == nil, let validator, let modified = response.lastModified, modified != validator, !restartedThisRun {
            // FTP has no If-Range: a different modification time means the file changed.
            return restart(keeping: nil)
        }
        let matches = response.rangeAccepted && response.bodyOffset == link.offset
            && (response.totalSize == nil || response.totalSize == planner?.totalSize)
        if matches {
            if runURL == nil {
                runURL = response.finalURL
                state.finalURL = response.finalURL
            }
            return
        }
        if response.statusCode == 200 || response.totalSize != planner?.totalSize {
            // The whole file came back: it changed on the server (If-Range failed) or ranges stopped working.
            if restartedThisRun {
                drop(link)
                connectionCap = max(1, links.count)
                return
            }
            return restart(keeping: response.bodyOffset == 0 ? (link, response) : nil)
        }
        linkFailed(link, .unexpectedRange)
    }

    public func connection(_ connection: TransferConnection, didReceive data: Data) {
        guard let link = link(for: connection) else { return }
        if link.resumeAt != nil {
            link.pending.append(data)
            return
        }
        handleData(data, on: link)
    }

    public func connection(_ connection: TransferConnection, didCompleteWith error: DownloadFailure?) {
        guard let link = link(for: connection) else { return }
        if link.resumeAt != nil || !link.pending.isEmpty {
            link.pendingCompletion = .some(error)
            return
        }
        handleCompletion(of: link, error: error)
    }

    private func handleData(_ data: Data, on link: Link) {
        guard let segmentID = link.segmentID, planner != nil else { return }
        var remaining = data[...]
        var currentSegment = segmentID
        while !remaining.isEmpty, running {
            guard let segment = planner?.segment(currentSegment) else { return }
            let position = segment.position
            let accepted = planner?.record(bytes: Int64(remaining.count), in: currentSegment) ?? 0
            if accepted > 0 {
                do {
                    try writer?.write(Data(remaining.prefix(Int(accepted))), at: position)
                } catch {
                    return fail(error as? DownloadFailure ?? .fileSystem(error.localizedDescription))
                }
                remaining = remaining.dropFirst(Int(accepted))
                retries[currentSegment] = 0
                received(accepted, on: link)
            }
            guard planner?.segment(currentSegment)?.isFinished == true else { return }
            switch planner?.reachedEnd(currentSegment) ?? .finished {
            case .continued(let cancelled):
                if let cancelled, let other = links.values.first(where: { $0.segmentID == cancelled }) {
                    links.removeValue(forKey: ObjectIdentifier(other.connection))
                    other.connection.cancel()
                }
                currentSegment = segmentID
            case .finished:
                links.removeValue(forKey: ObjectIdentifier(link.connection))
                link.connection.cancel()
                if planner?.isComplete == true { return finish() }
                fillSlots()
                return
            }
        }
        if planner?.isComplete == true { finish() }
    }

    private func handleCompletion(of link: Link, error: DownloadFailure?) {
        links.removeValue(forKey: ObjectIdentifier(link.connection))
        if error == nil {
            if planner?.totalSize == nil, link.segmentID != nil {
                planner?.finishUnknownLength()
                state.totalBytes = planner?.totalSize
                return finish()
            }
            if planner?.isComplete == true { return finish() }
        }
        linkFailed(link, error ?? .connectionClosedEarly)
    }

    // MARK: - Response handling

    private func adoptProbe(_ link: Link, _ response: TransferResponse) {
        runURL = response.finalURL
        state.finalURL = response.finalURL
        state.etag = response.etag
        state.lastModified = response.lastModified
        state.totalBytes = response.totalSize
        state.resumable = response.statusCode == 206 && response.totalSize != nil
            || (response.statusCode == nil && response.acceptsRanges && response.totalSize != nil)
        if state.fileName.isEmpty {
            state.fileName = FileNameResolver.fileName(contentDisposition: response.contentDisposition, url: response.finalURL, mimeType: response.mimeType)
        }
        validator = configuration.ignoreModificationTimeChanges ? nil : (state.etag ?? state.lastModified)
        var newPlanner = SegmentPlanner(totalSize: response.totalSize, minSegmentSize: configuration.minSegmentSize)
        let first = newPlanner.assign()
        planner = newPlanner
        link.isProbe = false
        link.segmentID = first?.id
        if let total = response.totalSize {
            do { try writer?.setLength(total) } catch { return fail(.fileSystem(error.localizedDescription)) }
        }
        publish(.started(state))
        if planner?.isComplete == true { return finish() }
        fillSlots()
    }

    /// Starts over from byte 0, optionally reusing a connection that is already sending the whole file.
    private func restart(keeping reuse: (link: Link, response: TransferResponse)?) {
        restartedThisRun = true
        for other in links.values where other !== reuse?.link {
            other.connection.cancel()
        }
        links = links.filter { $0.value === reuse?.link }
        resetProgress()
        do { try writer?.open(truncate: true) } catch { return fail(.fileSystem(error.localizedDescription)) }
        if let reuse {
            reuse.link.isProbe = true
            reuse.link.offset = 0
            var response = reuse.response
            response.statusCode = response.acceptsRanges ? 206 : 200
            adoptProbe(reuse.link, response)
        } else {
            openProbe(useRange: true)
        }
    }

    private func linkFailed(_ link: Link, _ failure: DownloadFailure) {
        drop(link)
        guard failure.isRetryable else { return fail(failure) }
        let key = link.segmentID ?? Self.probeKey
        let attempts = (retries[key] ?? 0) + 1
        retries[key] = attempts
        if attempts > configuration.retriesPerConnection {
            if links.isEmpty { fail(failure) }
            return
        }
        let wasProbe = planner == nil || !state.resumable
        queue.asyncAfter(deadline: .now() + configuration.retryDelay * Double(attempts)) { [self] in
            guard running else { return }
            if wasProbe {
                guard links.isEmpty else { return }
                let probeAttempts = retries[key] ?? attempts
                let useRange = state.resumable || state.downloadedBytes == 0
                resetProgress()
                retries[Self.probeKey] = probeAttempts
                do { try writer?.open(truncate: true) } catch { return fail(.fileSystem(error.localizedDescription)) }
                openProbe(useRange: useRange)
            } else {
                fillSlots()
            }
        }
    }

    // MARK: - Progress, completion, failure

    private func received(_ bytes: Int64, on link: Link) {
        state.downloadedBytes = planner?.downloadedBytes ?? state.downloadedBytes + bytes
        // Speed, checkpoints and progress pacing follow real time, whatever clock the engine uses for dates.
        let now = Date()
        speedSamples.append((now, state.downloadedBytes))
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 4 }
        engine.quota?.record(bytes)

        var delay = engine.limiter.consume(bytes, for: id)
        if let next = engine.quota?.nextAllowedAt { delay = max(delay, next.timeIntervalSince(now)) }
        if delay > 0.002 {
            let target = Date().addingTimeInterval(delay)
            if let current = link.resumeAt {
                link.resumeAt = max(current, target)
            } else {
                link.resumeAt = target
                if !link.isSuspended {
                    link.isSuspended = true
                    link.connection.suspend()
                }
                scheduleResume(link)
            }
        }

        if now.timeIntervalSince(lastCheckpoint) >= configuration.checkpointInterval {
            lastCheckpoint = now
            writer?.sync()
            saveProgressIntoState()
            publish(.checkpoint(state))
        }
        if now.timeIntervalSince(lastProgress) >= 0.2 {
            lastProgress = now
            publish(.progress(progressSnapshot()))
        }
    }

    /// Resumes a throttled connection once its (possibly extended) pause is over.
    private func scheduleResume(_ link: Link) {
        let wait = max(0, (link.resumeAt ?? Date()).timeIntervalSinceNow)
        queue.asyncAfter(deadline: .now() + wait) { [self, weak link] in
            guard let link, links[ObjectIdentifier(link.connection)] === link, let resumeAt = link.resumeAt else { return }
            if resumeAt.timeIntervalSinceNow > 0.001 { return scheduleResume(link) }
            link.resumeAt = nil
            while link.resumeAt == nil, !link.pending.isEmpty, links[ObjectIdentifier(link.connection)] === link {
                handleData(link.pending.removeFirst(), on: link)
            }
            guard link.resumeAt == nil, links[ObjectIdentifier(link.connection)] === link else { return }
            if let completion = link.pendingCompletion {
                link.pendingCompletion = nil
                handleCompletion(of: link, error: completion)
            } else if link.isSuspended {
                link.isSuspended = false
                link.connection.resume()
            }
        }
    }

    private func progressSnapshot() -> DownloadProgressSnapshot {
        var speed = 0.0
        if let first = speedSamples.first, let last = speedSamples.last, last.time > first.time {
            speed = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        }
        return DownloadProgressSnapshot(
            id: id,
            downloadedBytes: state.downloadedBytes,
            totalBytes: state.totalBytes,
            bytesPerSecond: speed,
            activeConnections: links.count,
            resumable: state.resumable,
            segments: planner?.progress() ?? SegmentProgress(bars: [], downloadedBytes: 0, totalBytes: 0)
        )
    }

    private func saveProgressIntoState() {
        if let planner {
            state.segments = planner.totalSize == nil ? [] : planner.records
            state.downloadedBytes = planner.downloadedBytes
        }
    }

    private func finish() {
        guard running else { return }
        stopAllLinks()
        running = false
        let total = planner?.totalSize ?? state.downloadedBytes
        do {
            try writer?.setLength(total)
            writer?.sync()
            writer?.close()
            let folder = URL(fileURLWithPath: state.directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if state.fileName.isEmpty { state.fileName = "download" }
            let destination = FileNameResolver.uniqueURL(for: folder.appendingPathComponent(state.fileName))
            try FileManager.default.moveItem(at: temporaryFileURL, to: destination)
            state.fileName = destination.lastPathComponent
        } catch {
            running = true
            return fail(.fileSystem(error.localizedDescription))
        }
        state.status = .completed
        state.totalBytes = total
        state.downloadedBytes = total
        state.segments = []
        state.dateCompleted = engine.clock.now
        state.errorMessage = nil
        publish(.completed(state))
    }

    private func fail(_ failure: DownloadFailure) {
        guard running else { return }
        stopAllLinks()
        running = false
        writer?.sync()
        writer?.close()
        saveProgressIntoState()
        if state.downloadedBytes == 0 {
            try? FileManager.default.removeItem(at: temporaryFileURL)
        }
        state.status = .failed
        state.errorMessage = failure.message
        publish(.failed(state))
    }

    private func publish(_ event: Event) {
        snapshotLock.withLock { snapshot = state }
        onEvent(event)
    }
}
