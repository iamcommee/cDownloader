import Foundation
import Observation

/// The app's single source of truth: the download list, queues, categories and settings.
/// It creates jobs, follows their events, runs queues and saves everything to disk.
@MainActor
@Observable
public final class DownloadLibrary {
    public private(set) var items: [DownloadItem] = []
    public private(set) var queues: [DownloadQueue] = []
    public private(set) var categories: [DownloadCategory] = []
    public private(set) var progress: [UUID: DownloadProgressSnapshot] = [:]
    public var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    // UI hooks
    @ObservationIgnored public var onNeedsConfirmation: (DownloadItem) -> Void = { _ in }
    @ObservationIgnored public var onNeedsSelection: ([DownloadItem]) -> Void = { _ in }
    @ObservationIgnored public var onDownloadCompleted: (DownloadItem) -> Void = { _ in }
    @ObservationIgnored public var onDownloadFailed: (DownloadItem) -> Void = { _ in }
    @ObservationIgnored public var onQuitRequested: () -> Void = {}
    @ObservationIgnored public var onShowWindow: () -> Void = {}
    @ObservationIgnored public var onQueueFinished: (DownloadQueue) -> Void = { _ in }
    /// How a finished download's file is thrown away when it is deleted with its file. Tests replace it.
    @ObservationIgnored public var discardFile: @Sendable (URL) -> Void = DownloadLibrary.moveToTrash

    /// Moves a file to the Trash, so a mistake can be undone; deletes it when the Trash cannot take it (for
    /// example on a network drive).
    public static let moveToTrash: @Sendable (URL) -> Void = { url in
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @ObservationIgnored public let engine: DownloadEngine
    @ObservationIgnored public let runner: QueueRunner
    @ObservationIgnored public let secrets: SecretStore
    @ObservationIgnored let clock: TimeSource
    @ObservationIgnored let downloadsRoot: URL
    @ObservationIgnored let storeDirectory: URL
    /// Number of library writes, for tests of the save debounce.
    @ObservationIgnored var saveCount = 0

    @ObservationIgnored private let libraryStore: JSONStore<LibraryState>
    @ObservationIgnored private let settingsStore: JSONStore<AppSettings>
    @ObservationIgnored private let configureEngine: (inout EngineConfiguration) -> Void
    @ObservationIgnored private let quota: DownloadQuota
    @ObservationIgnored private var jobs: [UUID: DownloadRunner] = [:]
    @ObservationIgnored private var restartAfterPause: Set<UUID> = []
    @ObservationIgnored private var replaceFileOnStart: Set<UUID> = []
    @ObservationIgnored private var quitAfter: Set<UUID> = []
    /// Removed downloads whose job was still stopping; their temporary files go once it has stopped.
    @ObservationIgnored private var removedWhileRunning: Set<UUID> = []
    @ObservationIgnored private var dirtySince: Date?

    public static let saveDelay: TimeInterval = 1

    public init(
        storeDirectory: URL,
        secrets: SecretStore,
        clock: TimeSource = SystemTimeSource(),
        downloadsRoot: URL,
        configure: @escaping (inout EngineConfiguration) -> Void = { _ in }
    ) {
        self.storeDirectory = storeDirectory
        self.secrets = secrets
        self.clock = clock
        self.downloadsRoot = downloadsRoot
        self.configureEngine = configure
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        libraryStore = JSONStore(fileURL: storeDirectory.appendingPathComponent("library.json"), defaultValue: { LibraryState() })
        settingsStore = JSONStore(fileURL: storeDirectory.appendingPathComponent("settings.json"), defaultValue: { AppSettings() })

        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        quota = DownloadQuota(
            limitBytes: Int64(loadedSettings.quota.megabytes) * 1_048_576,
            period: TimeInterval(loadedSettings.quota.hours) * 3600,
            enabled: loadedSettings.quota.enabled,
            clock: clock
        )
        var configuration = EngineConfiguration(settings: loadedSettings, defaultTemporaryDirectory: storeDirectory.appendingPathComponent("Temp", isDirectory: true))
        configure(&configuration)
        engine = DownloadEngine(configuration: configuration, secrets: secrets, quota: quota, clock: clock)
        YtDlp.removeLeftoverSignIns(in: configuration.temporaryDirectory)

        let state = libraryStore.load()
        var loadedQueues = state.queues
        for main in DownloadQueue.defaults().reversed() where !loadedQueues.contains(where: { $0.id == main.id }) {
            loadedQueues.insert(main, at: 0)
        }
        runner = QueueRunner(queues: loadedQueues, clock: clock)
        queues = loadedQueues
        categories = state.categories.isEmpty ? CategoryCatalog.defaults(root: downloadsRoot) : state.categories
        items = state.downloads.map { item in
            var item = item
            if item.status == .downloading || item.status == .waiting { item.status = .stopped }
            return item
        }
        applyLimiter()
        wireRunner()
    }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        guard old != settings else { return }
        try? settingsStore.save(settings)
        if Self.engineFieldsDiffer(old, settings) {
            engine.update(configuration: makeEngineConfiguration())
        }
        applyLimiter()
        quota.configure(
            limitBytes: Int64(settings.quota.megabytes) * 1_048_576,
            period: TimeInterval(settings.quota.hours) * 3600,
            enabled: settings.quota.enabled
        )
    }

    private func makeEngineConfiguration() -> EngineConfiguration {
        var configuration = EngineConfiguration(settings: settings, defaultTemporaryDirectory: storeDirectory.appendingPathComponent("Temp", isDirectory: true))
        configureEngine(&configuration)
        return configuration
    }

    private static func engineFieldsDiffer(_ a: AppSettings, _ b: AppSettings) -> Bool {
        a.maxConnections != b.maxConnections || a.minSegmentKB != b.minSegmentKB || a.timeoutSeconds != b.timeoutSeconds
            || a.retriesPerConnection != b.retriesPerConnection || a.ignoreModificationTimeChanges != b.ignoreModificationTimeChanges
            || a.connectionExceptions != b.connectionExceptions || a.siteLogins != b.siteLogins
            || a.customUserAgent != b.customUserAgent || a.proxy != b.proxy || a.temporaryDirectory != b.temporaryDirectory
            || a.webVideoCookiesBrowser != b.webVideoCookiesBrowser
    }

    private func applyLimiter() {
        let limiter = settings.speedLimiter
        engine.limiter.globalLimit = limiter.enabled && limiter.bytesPerSecond > 0 ? limiter.bytesPerSecond : nil
    }

    // MARK: - Queue runner wiring

    private func wireRunner() {
        runner.startDownload = { [weak self] id in
            MainActor.assumeIsolated { self?.startJob(id) }
        }
        runner.stopDownload = { [weak self] id in
            MainActor.assumeIsolated { self?.jobs[id]?.pause() }
        }
        runner.itemStatus = { [weak self] id in
            MainActor.assumeIsolated { self?.item(id)?.status }
        }
        runner.queuesChanged = { [weak self] queues in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.queues = queues
                for queue in queues where queue.kind == .download {
                    for (index, item) in self.items.enumerated() where item.queueID == queue.id && !queue.itemIDs.contains(item.id) {
                        self.items[index].queueID = nil
                    }
                }
                self.markDirty()
            }
        }
        runner.performPostAction = { [weak self] queue in
            MainActor.assumeIsolated { self?.onQueueFinished(queue) }
        }
        runner.checkRemoteChanged = { [weak self] id, reply in
            MainActor.assumeIsolated {
                guard let item = self?.item(id) else { return reply(false) }
                Task { @MainActor in
                    let remote = await Self.remoteInfo(for: item)
                    let changed = RemoteFileInfo.hasChanged(item: item, remote: remote)
                    if changed { self?.replaceFileOnStart.insert(id) }
                    reply(changed)
                }
            }
        }
    }

    private static func remoteInfo(for item: DownloadItem) async -> RemoteFileInfo {
        var request = URLRequest(url: item.finalURL ?? item.url)
        request.httpMethod = "HEAD"
        request.setValue(item.userAgent ?? EngineConfiguration.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let cookies = item.cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return RemoteFileInfo(size: nil, lastModified: nil, etag: nil) }
        return RemoteFileInfo(
            size: response.expectedContentLength >= 0 ? response.expectedContentLength : nil,
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            etag: http.value(forHTTPHeaderField: "ETag")
        )
    }

    // MARK: - Adding

    private static let scriptExtensions: Set<String> = ["php", "asp", "aspx", "jsp", "cgi", "pl", "cfm", "html", "htm"]

    public func makeItem(from incoming: IncomingDownload, folder: String?) -> DownloadItem {
        let playlistTypes = ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"]
        let mime = incoming.mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // A YouTube page becomes a video of the chosen quality (or the default one), downloaded through yt-dlp.
        let webQuality = YouTubeLinks.classify(incoming.url) == nil
            ? nil : incoming.quality.flatMap(VideoQuality.init(rawValue:)) ?? settings.webVideoQuality
        let isStream = webQuality == nil && (incoming.kind == "hls" || incoming.url.pathExtension.lowercased() == "m3u8" || playlistTypes.contains(mime))
        var name = incoming.fileName.map(FileNameResolver.sanitize) ?? ""
        if name.isEmpty, !isStream, webQuality == nil {
            let fromURL = incoming.url.lastPathComponent == "/" ? "" : FileNameResolver.sanitize(incoming.url.lastPathComponent)
            let ext = (fromURL as NSString).pathExtension.lowercased()
            if !ext.isEmpty, !Self.scriptExtensions.contains(ext) { name = fromURL }
        }
        let categoryProbe = webQuality.map { $0 == .audio ? "audio.m4a" : "video.mp4" }
            ?? (isStream ? "stream.m3u8" : (name.isEmpty ? incoming.url.lastPathComponent : name))
        let category = CategoryCatalog.suggest(fileName: categoryProbe, in: categories)
        var item = DownloadItem(url: incoming.url, fileName: name, directory: folder ?? category?.folder ?? downloadsRoot.path, dateAdded: clock.now)
        item.categoryID = category?.id
        item.referer = incoming.referer
        item.cookies = incoming.cookies
        item.userAgent = incoming.userAgent
        if isStream { item.kind = .hls(variantIndex: nil) }
        if let webQuality { item.kind = .webVideo(quality: webQuality) }
        return item
    }

    /// Like `makeItem`, but a YouTube playlist link becomes one item per video in it, named after the video.
    /// When the list cannot be read, the link stays one item and its description says why.
    public func makeItemsExpandingPlaylists(_ downloads: [IncomingDownload], folder: String?) async -> [DownloadItem] {
        var made: [DownloadItem] = []
        for download in downloads {
            guard case .playlist = YouTubeLinks.classify(download.url) else {
                made.append(makeItem(from: download, folder: folder))
                continue
            }
            let configuration = engine.currentConfiguration
            do {
                guard let tool = configuration.ytDlpPath ?? YtDlp.locate(), FileManager.default.isExecutableFile(atPath: tool) else {
                    throw YtDlpPlaylist.Failure(message: YtDlp.missingMessage)
                }
                let entries = try await YtDlpPlaylist.expand(
                    url: download.url, executable: tool, cookiesHeader: download.cookies, browser: configuration.ytDlpCookiesBrowser,
                    temporaryDirectory: configuration.temporaryDirectory, environment: configuration.toolEnvironment,
                    timeout: configuration.playlistTimeout, stopGrace: configuration.toolStopGrace
                )
                guard !entries.isEmpty else { throw YtDlpPlaylist.Failure(message: "It has no videos that can be downloaded.") }
                made += entries.map { entry in
                    makeItem(from: IncomingDownload(
                        url: YouTubeLinks.watchURL(id: entry.id), referer: download.referer, fileName: entry.title.isEmpty ? nil : entry.title,
                        cookies: download.cookies, userAgent: download.userAgent, kind: "youtube", quality: download.quality
                    ), folder: folder)
                }
            } catch {
                var item = makeItem(from: download, folder: folder)
                let reason = (error as? YtDlpPlaylist.Failure)?.message ?? error.localizedDescription
                item.descriptionText = "The playlist's videos could not be read. \(reason)"
                made.append(item)
            }
        }
        return made
    }

    /// Adds an item. Unstarted items without a queue go to the main download queue.
    public func add(_ item: DownloadItem, start: Bool, queueID: UUID? = nil) {
        var item = item
        let targetQueue = queueID ?? (start ? nil : DownloadQueue.mainDownloadID)
        item.queueID = targetQueue
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        if let targetQueue, let index = queues.firstIndex(where: { $0.id == targetQueue }), !queues[index].itemIDs.contains(item.id) {
            queues[index].itemIDs.append(item.id)
            runner.setQueues(queues)
        }
        markDirty()
        if start { startJob(item.id) }
    }

    public func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    /// Replaces an item's editable fields (properties dialog).
    public func update(_ item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        markDirty()
    }

    // MARK: - Control

    public func start(_ id: UUID) {
        startJob(id)
    }

    private func startJob(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if jobs[id] != nil {
            if restartAfterPause.contains(id) { return }
            return
        }
        if items[index].status == .completed {
            guard replaceFileOnStart.contains(id) else { return }
            resetForRedownload(index)
        }
        replaceFileOnStart.remove(id)
        items[index].status = .downloading
        items[index].errorMessage = nil
        let job = engine.makeRunner(for: items[index]) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, for: id) }
            }
        }
        jobs[id] = job
        markDirty()
        job.start()
    }

    public func pause(_ id: UUID) {
        restartAfterPause.remove(id)
        if let job = jobs[id] {
            job.pause()
        } else if let index = items.firstIndex(where: { $0.id == id }), items[index].status == .waiting {
            items[index].status = .stopped
        }
    }

    public func stopAll() {
        for queue in queues where runner.isRunning(queue.id) { runner.stop(queue.id) }
        for id in jobs.keys { pause(id) }
    }

    public func isRunning(_ id: UUID) -> Bool { jobs[id] != nil }

    public func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        for id in ids {
            guard let item = item(id) else { continue }
            if let job = jobs.removeValue(forKey: id) {
                job.pause()
                removedWhileRunning.insert(id)
            }
            progress[id] = nil
            quitAfter.remove(id)
            removeTemporaryFiles(of: id)
            // Only a finished download owns the file at its name; an unfinished one only had partial data.
            if deleteFiles, item.status == .completed, FileManager.default.fileExists(atPath: item.destinationURL.path) {
                discardFile(item.destinationURL)
            }
            engine.limiter.remove(id)
        }
        items.removeAll { ids.contains($0.id) }
        for index in queues.indices { queues[index].itemIDs.removeAll { ids.contains($0) } }
        runner.setQueues(queues)
        // The removed job's own "paused" event is ignored (the item is gone), so tell the queue now.
        for id in ids { runner.downloadFinished(id, outcome: .stopped) }
        markDirty()
    }

    public func removeCompleted() {
        remove(Set(items.filter { $0.status == .completed }.map(\.id)), deleteFiles: false)
    }

    /// Starts the download again from scratch; the old finished file is moved to the Trash.
    public func redownload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let job = jobs[id] {
            restartAfterPause.insert(id)
            replaceFileOnStart.insert(id)
            job.pause()
            return
        }
        resetForRedownload(index)
        startJob(id)
    }

    private func resetForRedownload(_ index: Int) {
        let item = items[index]
        if item.status == .completed, FileManager.default.fileExists(atPath: item.destinationURL.path) {
            if (try? FileManager.default.trashItem(at: item.destinationURL, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: item.destinationURL)
            }
        }
        removeTemporaryFiles(of: item.id)
        items[index].status = .stopped
        items[index].downloadedBytes = 0
        items[index].totalBytes = nil
        items[index].segments = []
        items[index].resumable = false
        items[index].etag = nil
        items[index].lastModified = nil
        items[index].dateCompleted = nil
        items[index].errorMessage = nil
        progress[item.id] = nil
    }

    private func removeTemporaryFiles(of id: UUID) {
        let folder = engine.currentConfiguration.temporaryDirectory
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).part"))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).hls", isDirectory: true))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).ytdlp", isDirectory: true))
    }

    public func setSpeedLimit(_ id: UUID, bytesPerSecond: Int64?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let limit = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        items[index].speedLimit = limit
        engine.limiter.setLimit(limit, for: id)
        markDirty()
    }

    /// The next browser download with the same file name replaces this item's address.
    public func requestAddressRefresh(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].awaitingAddressRefresh = true
        markDirty()
    }

    private func applyAddressRefresh(_ incoming: DownloadItem) -> Bool {
        guard !incoming.fileName.isEmpty,
              let index = items.firstIndex(where: { $0.awaitingAddressRefresh && $0.fileName == incoming.fileName })
        else { return false }
        items[index].url = incoming.url
        items[index].finalURL = nil
        if incoming.referer != nil { items[index].referer = incoming.referer }
        if incoming.cookies != nil { items[index].cookies = incoming.cookies }
        if incoming.userAgent != nil { items[index].userAgent = incoming.userAgent }
        items[index].awaitingAddressRefresh = false
        markDirty()
        return true
    }

    // MARK: - Job events

    private func handle(_ event: DownloadJob.Event, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            // A removed download's tool may still write while it stops; what it left goes once it has stopped.
            switch event {
            case .paused, .failed, .completed:
                if removedWhileRunning.remove(id) != nil { removeTemporaryFiles(of: id) }
            case .started, .progress, .checkpoint:
                break
            }
            return
        }
        switch event {
        case .started(let item), .checkpoint(let item):
            merge(item, at: index)
            markDirty()
        case .progress(let snapshot):
            progress[id] = snapshot
            items[index].downloadedBytes = snapshot.downloadedBytes
            if let total = snapshot.totalBytes { items[index].totalBytes = total }
        case .paused(let item):
            merge(item, at: index)
            finishJob(id)
            runner.downloadFinished(id, outcome: .stopped)
            if restartAfterPause.remove(id) != nil {
                if replaceFileOnStart.remove(id) != nil { resetForRedownload(index) }
                startJob(id)
            }
        case .completed(let item):
            merge(item, at: index)
            finishJob(id)
            onDownloadCompleted(items[index])
            runner.downloadFinished(id, outcome: .completed)
            if quitAfter.remove(id) != nil { onQuitRequested() }
        case .failed(let item):
            merge(item, at: index)
            finishJob(id)
            quitAfter.remove(id)
            onDownloadFailed(items[index])
            runner.downloadFinished(id, outcome: .failed)
        }
    }

    private func finishJob(_ id: UUID) {
        jobs[id] = nil
        progress[id] = nil
        markDirty()
    }

    /// Copies what the engine knows; fields the user edits stay as they are.
    private func merge(_ engineItem: DownloadItem, at index: Int) {
        var item = items[index]
        item.status = engineItem.status
        item.fileName = engineItem.fileName
        item.totalBytes = engineItem.totalBytes
        item.downloadedBytes = engineItem.downloadedBytes
        item.resumable = engineItem.resumable
        item.segments = engineItem.segments
        item.etag = engineItem.etag
        item.lastModified = engineItem.lastModified
        item.finalURL = engineItem.finalURL
        item.errorMessage = engineItem.errorMessage
        item.lastTry = engineItem.lastTry
        item.dateCompleted = engineItem.dateCompleted
        items[index] = item
    }

    // MARK: - Queues

    @discardableResult
    public func addQueue(name: String, kind: QueueKind) -> DownloadQueue {
        let queue = DownloadQueue(name: name, kind: kind)
        queues.append(queue)
        runner.setQueues(queues)
        markDirty()
        return queue
    }

    /// Custom queues only; their downloads stay in the list without a queue.
    public func deleteQueue(_ id: UUID) {
        guard let queue = queues.first(where: { $0.id == id }), !queue.isMain else { return }
        runner.stop(id)
        queues.removeAll { $0.id == id }
        for index in items.indices where items[index].queueID == id { items[index].queueID = nil }
        runner.setQueues(queues)
        markDirty()
    }

    public func updateQueue(_ queue: DownloadQueue) {
        guard let index = queues.firstIndex(where: { $0.id == queue.id }) else { return }
        queues[index] = queue
        runner.setQueues(queues)
        markDirty()
    }

    /// Moves downloads into a queue (in the given order), or out of every queue when `queueID` is nil.
    public func moveItems(_ ids: [UUID], toQueue queueID: UUID?) {
        let known = ids.filter { item($0) != nil }
        for index in queues.indices { queues[index].itemIDs.removeAll { known.contains($0) } }
        if let queueID, let target = queues.firstIndex(where: { $0.id == queueID }) {
            queues[target].itemIDs.append(contentsOf: known)
        }
        for index in items.indices where known.contains(items[index].id) { items[index].queueID = queueID }
        runner.setQueues(queues)
        markDirty()
    }

    public func startQueue(_ id: UUID) {
        runner.setQueues(queues)
        runner.start(id)
    }

    public func stopQueue(_ id: UUID) {
        runner.stop(id)
    }

    public func isQueueRunning(_ id: UUID) -> Bool { runner.isRunning(id) }

    // MARK: - Categories

    public func addCategory(_ category: DownloadCategory) {
        categories.append(category)
        markDirty()
    }

    public func updateCategory(_ category: DownloadCategory) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        categories[index] = category
        markDirty()
    }

    /// General cannot be deleted; downloads of a deleted category fall back to General.
    public func deleteCategory(_ id: String) {
        guard id != DownloadCategory.generalID else { return }
        categories.removeAll { $0.id == id }
        for index in items.indices where items[index].categoryID == id { items[index].categoryID = DownloadCategory.generalID }
        markDirty()
    }

    // MARK: - Requests from the browser and the command line

    public func handle(_ request: IPCRequest) async -> IPCReply {
        switch request.type {
        case .ping:
            return IPCReply(ok: true)
        case .getConfig:
            return IPCReply(ok: true, config: BrowserConfig(settings: settings))
        case .showWindow:
            onShowWindow()
            return IPCReply(ok: true)
        case .startQueue:
            startQueue(DownloadQueue.mainDownloadID)
            return IPCReply(ok: true)
        case .add:
            let valid = (request.downloads ?? []).filter { download in
                let scheme = download.url.scheme?.lowercased() ?? ""
                return ["http", "https", "ftp"].contains(scheme) && download.url.host?.isEmpty == false
            }
            guard !valid.isEmpty else { return IPCReply(ok: false, error: "No valid download address") }
            if valid.contains(where: { if case .playlist = YouTubeLinks.classify($0.url) { true } else { false } }) {
                // Reading a playlist can take longer than the browser waits for an answer, so it answers first.
                Task { deliver(await makeItemsExpandingPlaylists(valid, folder: request.folder), for: request) }
                return IPCReply(ok: true)
            }
            deliver(valid.map { makeItem(from: $0, folder: request.folder) }, for: request)
            return IPCReply(ok: true)
        }
    }

    /// Hands new items to the right place: started at once, queued, offered as a list or in the start dialog.
    private func deliver(_ made: [DownloadItem], for request: IPCRequest) {
        let newItems = made.filter { !applyAddressRefresh($0) }
        if request.quitAfter == true { quitAfter.formUnion(newItems.map(\.id)) }
        guard !newItems.isEmpty else { return }
        if request.silent == true {
            newItems.forEach { add($0, start: true) }
        } else if request.addOnly == true {
            newItems.forEach { add($0, start: false, queueID: DownloadQueue.mainDownloadID) }
        } else if request.showList == true || newItems.count > 1 {
            onNeedsSelection(newItems)
        } else if settings.showStartDialog {
            onNeedsConfirmation(newItems[0])
        } else {
            add(newItems[0], start: true)
        }
    }

    // MARK: - Persistence

    private func markDirty() {
        if dirtySince == nil { dirtySince = clock.now }
    }

    public func flush() {
        try? libraryStore.save(LibraryState(downloads: items, queues: queues, categories: categories))
        saveCount += 1
        dirtySince = nil
    }

    /// Advances queue retries and schedules and saves pending changes; the app calls this about once a second.
    public func tick() {
        runner.tick()
        if let since = dirtySince, clock.now.timeIntervalSince(since) >= Self.saveDelay {
            flush()
        }
    }
}
