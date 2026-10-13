import AppKit
import cDownloaderCore
import Foundation
import Observation

enum SidebarItem: Hashable {
    case all
    case unfinished
    case finished
    case category(String)
    case queue(UUID)
    case grabberProject(UUID)
}

/// Windows the model asks the root view to open (SwiftUI only lets views open windows).
enum WindowRequest: Equatable {
    case main
    case scheduler
    case grabber(UUID?)
    case dropTarget
}

/// Connects the download library to the windows and runs the background services.
@MainActor
@Observable
final class AppModel {
    let library: DownloadLibrary

    // Main window state
    var sidebarSelection: SidebarItem = .all
    var selection: Set<UUID> = []
    var searchText = ""

    // Sheets
    var showAddURL = false
    var addURLPrefill = ""
    var pendingInfo: DownloadItem?
    var pendingInfoQuitAfter = false
    var pendingSelection: [DownloadItem]?
    var showBatch = false
    var showImportLinks: [DownloadItem]?
    var zipPreviewItem: DownloadItem?
    var propertiesItem: DownloadItem?
    var errorMessage: String?

    // Window requests consumed by the root view
    var windowRequests: [WindowRequest] = []

    /// The finished download shown in the banner at the top of the main window, until it fades away.
    var completionBanner: UUID?
    @ObservationIgnored private var bannerTimer: Task<Void, Never>?

    // Site grabber projects
    private(set) var grabberProjects: [GrabberProject] = []
    @ObservationIgnored private let grabberStore: JSONStore<[GrabberProject]>
    @ObservationIgnored private var grabberRuns: [UUID: Task<Void, Never>] = [:]
    var grabberProgress: [UUID: GrabberProgress] = [:]

    @ObservationIgnored private var ipcServer: IPCServer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let clipboard = ClipboardMonitor()
    @ObservationIgnored private var lastSpeedLimiterState: Bool?
    @ObservationIgnored private var toolUpdates: Task<Void, Never>?

    init() {
        // Before the library looks for yt-dlp: the packed copy is moved into the app's own folder, where it runs.
        let tools = YtDlpUpdater()
        tools.prepare()
        let support = AppPaths.supportDirectory
        let downloadsRoot = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        library = DownloadLibrary(storeDirectory: support, secrets: KeychainSecretStore(), downloadsRoot: downloadsRoot)
        grabberStore = JSONStore(fileURL: AppPaths.grabberProjectsFile, defaultValue: { [] })
        grabberProjects = grabberStore.load()

        if library.settings.speedLimiter.turnOnAtStartup, !library.settings.speedLimiter.enabled {
            library.settings.speedLimiter.enabled = true
        }
        wireLibrary()
        startIPC()
        BrowserIntegration.register()
        Notifier.requestPermission()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        startToolUpdates(tools)
        DockIcon.start(model: self)
    }

    /// Lets yt-dlp update itself in the background, since YouTube changes often: a look at launch and every few
    /// hours, while the updater itself goes online at most once a day.
    private func startToolUpdates(_ updater: YtDlpUpdater) {
        guard !AppPaths.isTestMode else { return }
        toolUpdates = Task.detached(priority: .background) {
            while !Task.isCancelled {
                _ = await updater.updateIfDue()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: - Wiring

    private func wireLibrary() {
        library.onNeedsConfirmation = { [weak self] item in
            self?.present { $0.pendingInfo = item }
        }
        library.onNeedsSelection = { [weak self] items in
            self?.present { $0.pendingSelection = items }
        }
        library.onShowWindow = { [weak self] in
            self?.request(.main)
        }
        library.onQuitRequested = {
            NSApp.terminate(nil)
        }
        library.onDownloadCompleted = { [weak self] item in
            self?.downloadCompleted(item)
        }
        library.onDownloadFailed = { [weak self] item in
            guard let self else { return }
            SoundPlayer.play(.downloadFailed, settings: library.settings.sounds)
            Notifier.post(title: String(localized: "Download failed"), body: "\(item.fileName): \(item.errorMessage ?? "")")
        }
        library.onQueueFinished = { [weak self] queue in
            guard let self else { return }
            SoundPlayer.play(.queueFinished, settings: library.settings.sounds)
            Notifier.post(title: String(localized: "Queue finished"), body: queue.name)
            PostActionRunner.run(queue.postAction)
        }
    }

    private func present(_ change: (AppModel) -> Void) {
        request(.main)
        NSApp.activate(ignoringOtherApps: true)
        change(self)
    }

    func request(_ window: WindowRequest) {
        // Only a visible view can open windows; when the main window is closed, reopen it through its URL scheme.
        let mainVisible = NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }
        // Back in the Dock and active before a window opens, so it opens once, without a redraw halfway. The floating
        // drop target alone does not need the Dock, but the main window opened below for it does.
        if window != .dropTarget || !mainVisible {
            DockIcon.showInDock()
        }
        windowRequests.append(window)
        if !mainVisible, let url = URL(string: "cdownloader://show") {
            NSApp.activate(ignoringOtherApps: true)
            NSWorkspace.shared.open(url)
        }
    }

    private func startIPC() {
        let library = self.library
        let server = IPCServer(socketPath: AppPaths.socketPath) { request in
            await library.handle(request)
        }
        do {
            try server.start()
            ipcServer = server
        } catch {
            NSLog("cDownloader: cannot listen for the browser and command line: \(error)")
        }
    }

    func shutdown() {
        library.flush()
        ipcServer?.stop()
    }

    private func tick() {
        library.tick()
        if library.settings.clipboardMonitoring, let url = clipboard.check(extensions: library.settings.capturedExtensions) {
            offer(url)
        }
        runScheduledGrabberProjects()
    }

    private func downloadCompleted(_ item: DownloadItem) {
        let settings = library.settings
        SoundPlayer.play(.downloadComplete, settings: settings.sounds)
        Notifier.post(title: String(localized: "Download complete"), body: item.fileName)
        ScanRunner.scan(item.destinationURL, settings: settings.scan)
        if settings.showCompleteDialog { showCompletionBanner(for: item.id) }
    }

    /// Shows the "download complete" banner in the main window. It fades away by itself after a few seconds, and
    /// never opens a window: with the window closed, the macOS notification is enough.
    func showCompletionBanner(for id: UUID) {
        completionBanner = id
        bannerTimer?.cancel()
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.completionBanner = nil
        }
    }

    // MARK: - Adding downloads

    /// Starts the "Download File Info" step for an address typed, pasted or dropped.
    /// A YouTube playlist is read first and offered as a list of its videos.
    func offer(_ url: URL, credentials: Credentials? = nil) {
        if case .playlist = YouTubeLinks.classify(url) {
            Task {
                let items = await library.makeItemsExpandingPlaylists([IncomingDownload(url: url)], folder: nil)
                if items.count > 1 { present { $0.pendingSelection = items } } else if let item = items.first { offer(item) }
            }
            return
        }
        offer(library.makeItem(from: IncomingDownload(url: url), folder: nil), credentials: credentials)
    }

    private func offer(_ prepared: DownloadItem, credentials: Credentials? = nil) {
        var item = prepared
        if let credentials {
            item.username = credentials.user
            library.secrets.setPassword(credentials.password, for: item.credentialKey)
        }
        if library.settings.showStartDialog {
            present { $0.pendingInfo = item }
        } else {
            library.add(item, start: true)
        }
    }

    /// Confirms the "Download File Info" dialog.
    func confirm(_ item: DownloadItem, startNow: Bool, queueID: UUID?) {
        var item = item
        if library.settings.rememberLastSavePath, let categoryID = item.categoryID,
           var category = library.categories.first(where: { $0.id == categoryID }), category.folder != item.directory {
            category.folder = item.directory
            library.updateCategory(category)
        }
        item.status = .stopped
        library.add(item, start: startNow, queueID: startNow ? nil : (queueID ?? DownloadQueue.mainDownloadID))
        // Its progress then shows in the details panel under the list.
        if startNow, library.settings.progressWindow != .hidden { selection = [item.id] }
    }

    func addMany(_ items: [DownloadItem], startNow: Bool, queueID: UUID?) {
        for item in items {
            library.add(item, start: false, queueID: queueID ?? DownloadQueue.mainDownloadID)
        }
        if startNow { library.startQueue(queueID ?? DownloadQueue.mainDownloadID) }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        let links = urls.filter { ["http", "https", "ftp"].contains($0.scheme?.lowercased() ?? "") }
        if links.count == 1 {
            offer(links[0])
        } else if links.count > 1 {
            Task {
                let items = await library.makeItemsExpandingPlaylists(links.map { IncomingDownload(url: $0) }, folder: nil)
                present { $0.pendingSelection = items }
            }
        }
    }

    /// Handles cdownloader://add?url=... links.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "cdownloader", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let target = components.queryItems?.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)) {
            offer(target)
        } else {
            request(.main)
        }
    }

    // MARK: - Import and export

    func importLinks(from file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        var urls: [URL]
        if file.pathExtension.lowercased() == "ef2" {
            let entries = EF2Codec.decode(data)
            pendingSelection = entries.map { entry in
                var item = library.makeItem(from: IncomingDownload(url: entry.url, referer: entry.referer, cookies: entry.cookie, userAgent: entry.userAgent), folder: nil)
                item.status = .stopped
                return item
            }
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        urls = LinkImporter.extractURLs(from: text)
        pendingSelection = urls.map { library.makeItem(from: IncomingDownload(url: $0), folder: nil) }
    }

    func export(_ items: [DownloadItem], to file: URL) {
        let data: Data
        if file.pathExtension.lowercased() == "ef2" {
            data = EF2Codec.encode(items.map { EF2Entry(url: $0.url, referer: $0.referer, userAgent: $0.userAgent, cookie: $0.cookies) })
        } else {
            data = Data(LinkImporter.exportPlainText(items.map(\.url)).utf8)
        }
        do { try data.write(to: file, options: .atomic) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Filtering for the list

    var visibleItems: [DownloadItem] {
        var result: [DownloadItem]
        switch sidebarSelection {
        case .all:
            result = library.items
        case .unfinished:
            result = library.items.filter { $0.status != .completed }
        case .finished:
            result = library.items.filter { $0.status == .completed }
        case .category(let id):
            result = library.items.filter { ($0.categoryID ?? DownloadCategory.generalID) == id }
        case .queue(let id):
            let order = library.queues.first { $0.id == id }?.itemIDs ?? []
            result = order.compactMap { library.item($0) }
        case .grabberProject(let id):
            let urls = Set(grabberProjects.first { $0.id == id }?.files.map(\.url) ?? [])
            result = library.items.filter { urls.contains($0.url) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.fileName.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query) || $0.descriptionText.localizedCaseInsensitiveContains(query) }
        }
        return result
    }

    var selectedItems: [DownloadItem] { selection.compactMap { library.item($0) } }

    var totalSpeed: Double { library.progress.values.reduce(0) { $0 + $1.bytesPerSecond } }

    var activeCount: Int { library.items.filter { $0.status == .downloading }.count }

    // MARK: - Speed limiter

    var speedLimiterOn: Bool {
        get { library.settings.speedLimiter.enabled }
        set { if library.settings.speedLimiter.enabled != newValue { library.settings.speedLimiter.enabled = newValue } }
    }

    // MARK: - Grabber

    func saveGrabberProject(_ project: GrabberProject) {
        if let index = grabberProjects.firstIndex(where: { $0.id == project.id }) {
            grabberProjects[index] = project
        } else {
            grabberProjects.append(project)
        }
        try? grabberStore.save(grabberProjects)
    }

    func deleteGrabberProject(_ id: UUID) {
        grabberRuns[id]?.cancel()
        grabberProjects.removeAll { $0.id == id }
        try? grabberStore.save(grabberProjects)
    }

    func isGrabbing(_ id: UUID) -> Bool { grabberRuns[id] != nil }

    /// Explores the site and stores the found files in the project.
    func runGrabber(_ project: GrabberProject, thenDownload: Bool = false) {
        saveGrabberProject(project)
        grabberRuns[project.id]?.cancel()
        let grabber = SiteGrabber(settings: project.settings)
        grabberProgress[project.id] = GrabberProgress(pagesExplored: 0, filesFound: 0, currentURL: project.settings.startURL)
        grabberRuns[project.id] = Task { [weak self] in
            let result = await grabber.run { progress in
                Task { @MainActor in self?.grabberProgress[project.id] = progress }
            }
            guard let self, !Task.isCancelled else { return }
            var updated = self.grabberProjects.first { $0.id == project.id } ?? project
            let previouslyUnchecked = Set(updated.files.filter { !$0.checked }.map(\.url))
            updated.files = result.files.map { file in
                var file = file
                if previouslyUnchecked.contains(file.url) { file.checked = false }
                return file
            }
            updated.pagesExplored = result.pagesExplored
            updated.lastRun = Date()
            self.saveGrabberProject(updated)
            self.grabberRuns[project.id] = nil
            if thenDownload || updated.settings.downloadAllAtOnce { self.downloadGrabberFiles(updated) }
        }
    }

    func stopGrabber(_ id: UUID) {
        grabberRuns[id]?.cancel()
        grabberRuns[id] = nil
    }

    /// Adds the checked files to the main list and the download queue, then starts the queue.
    func downloadGrabberFiles(_ project: GrabberProject) {
        let known = Set(library.items.map(\.url))
        let base = URL(fileURLWithPath: project.settings.saveFolder, isDirectory: true)
        for file in project.files where file.checked && !known.contains(file.url) {
            guard let target = file.destination(in: base) else { continue }
            var item = library.makeItem(from: IncomingDownload(url: file.url, referer: file.referer.absoluteString, fileName: target.lastPathComponent), folder: target.deletingLastPathComponent().path)
            item.descriptionText = String(localized: "Grabber: \(project.name)")
            library.add(item, start: false, queueID: DownloadQueue.mainDownloadID)
        }
        library.startQueue(DownloadQueue.mainDownloadID)
    }

    @ObservationIgnored private var lastGrabberCheck = Date()

    private func runScheduledGrabberProjects() {
        let now = Date()
        defer { lastGrabberCheck = now }
        for project in grabberProjects where !isGrabbing(project.id) {
            guard let schedule = project.schedule,
                  let next = QueueScheduler.nextStart(after: lastGrabberCheck, schedule: schedule, calendar: .current),
                  next <= now
            else { continue }
            runGrabber(project, thenDownload: true)
        }
    }
}
