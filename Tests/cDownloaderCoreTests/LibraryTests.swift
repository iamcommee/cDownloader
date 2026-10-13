import Foundation
import Testing
@testable import cDownloaderCore

/// Records the library's UI hooks.
@MainActor
final class LibraryHooks {
    var confirmations: [DownloadItem] = []
    var selections: [[DownloadItem]] = []
    var completed: [DownloadItem] = []
    var quitRequests = 0
    var showWindow = 0

    func attach(_ library: DownloadLibrary) {
        library.onNeedsConfirmation = { [weak self] in self?.confirmations.append($0) }
        library.onNeedsSelection = { [weak self] in self?.selections.append($0) }
        library.onDownloadCompleted = { [weak self] in self?.completed.append($0) }
        library.onQuitRequested = { [weak self] in self?.quitRequests += 1 }
        library.onShowWindow = { [weak self] in self?.showWindow += 1 }
    }
}

/// Keeps test servers alive for the whole test.
final class ServerBag: @unchecked Sendable {
    var servers: [LocalHTTPServer] = []
}

@MainActor
@Suite struct LibraryTests {
    let bag = ServerBag()
    let store = TempDir()
    let downloads = TempDir()
    let clock = TestClock()

    func makeLibrary(secrets: SecretStore = InMemorySecretStore(), configure: @escaping (inout EngineConfiguration) -> Void = { _ in }) -> (DownloadLibrary, LibraryHooks) {
        let library = DownloadLibrary(storeDirectory: store.url, secrets: secrets, clock: clock, downloadsRoot: downloads.url) { configuration in
            configuration.retryDelay = 0.05
            configuration.checkpointInterval = 0.05
            configuration.minSegmentSize = 32 * 1024
            configuration.timeout = 10
            configure(&configuration)
        }
        let hooks = LibraryHooks()
        hooks.attach(library)
        return (library, hooks)
    }

    func waitFor(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met in time")
        throw JobRecorder.TimeoutError()
    }

    // MARK: T15-01

    struct MakeRow: Sendable, CustomTestStringConvertible {
        var label: String
        var incoming: IncomingDownload
        var folder: String?
        var name: String?
        var category: String
        var hls = false
        /// T17-11: the exact kind expected, and the app's default YouTube quality.
        var kind: DownloadKind?
        var settingsQuality = VideoQuality.best
        var testDescription: String { label }
    }

    nonisolated static let watch = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    @Test(arguments: [
        MakeRow(label: "explicit name", incoming: IncomingDownload(url: URL(string: "https://h/x")!, fileName: "a.zip"), name: "a.zip", category: "Compressed"),
        MakeRow(label: "from URL", incoming: IncomingDownload(url: URL(string: "https://h/p/y%20z.mp4")!), name: "y z.mp4", category: "Video"),
        MakeRow(label: "empty", incoming: IncomingDownload(url: URL(string: "https://h/")!), name: "", category: "General"),
        MakeRow(label: "script URL waits for server name", incoming: IncomingDownload(url: URL(string: "https://h/get.php?id=4")!), name: "", category: "General"),
        MakeRow(label: "unknown ext", incoming: IncomingDownload(url: URL(string: "https://h/x")!, fileName: "b.xyz"), name: "b.xyz", category: "General"),
        MakeRow(label: "upper ext", incoming: IncomingDownload(url: URL(string: "https://h/x")!, fileName: "A.MP3"), name: "A.MP3", category: "Music"),
        MakeRow(label: "explicit folder", incoming: IncomingDownload(url: URL(string: "https://h/x")!, fileName: "a.pdf"), folder: "/custom", name: "a.pdf", category: "Documents"),
        MakeRow(label: "kind hls", incoming: IncomingDownload(url: URL(string: "https://h/a.mp4")!, kind: "hls"), category: "Video", hls: true),
        MakeRow(label: "kind m3u8", incoming: IncomingDownload(url: URL(string: "https://h/v/list.m3u8?x=1")!), category: "Video", hls: true),
        MakeRow(label: "playlist by type", incoming: IncomingDownload(url: URL(string: "https://h/play?id=4")!, mimeType: "application/vnd.apple.mpegurl"), category: "Video", hls: true),
        MakeRow(label: "playlist by type 2", incoming: IncomingDownload(url: URL(string: "https://h/play?id=5")!, mimeType: "audio/mpegurl; charset=utf-8"), category: "Video", hls: true),
        // T17-11
        MakeRow(label: "YouTube video", incoming: IncomingDownload(url: URL(string: watch)!), name: "", category: "Video", kind: .webVideo(quality: .best)),
        MakeRow(label: "YouTube video, default quality", incoming: IncomingDownload(url: URL(string: watch)!), category: "Video", kind: .webVideo(quality: .p480), settingsQuality: .p480),
        MakeRow(label: "YouTube video, chosen quality wins", incoming: IncomingDownload(url: URL(string: watch)!, quality: "720"), category: "Video", kind: .webVideo(quality: .p720)),
        MakeRow(label: "YouTube video, unknown quality", incoming: IncomingDownload(url: URL(string: watch)!, quality: "4k"), category: "Video", kind: .webVideo(quality: .p360), settingsQuality: .p360),
        MakeRow(label: "YouTube sound only", incoming: IncomingDownload(url: URL(string: watch)!, quality: "audio"), category: "Music", kind: .webVideo(quality: .audio)),
        MakeRow(label: "YouTube video, typed name", incoming: IncomingDownload(url: URL(string: watch)!, fileName: "Typed"), name: "Typed", category: "Video", kind: .webVideo(quality: .best)),
        MakeRow(label: "YouTube playlist on its own", incoming: IncomingDownload(url: URL(string: "https://www.youtube.com/playlist?list=PLabc_12-x")!), category: "Video", kind: .webVideo(quality: .best)),
        MakeRow(label: "YouTube short link", incoming: IncomingDownload(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!), category: "Video", kind: .webVideo(quality: .best)),
        MakeRow(label: "YouTube channel stays a page (guard)", incoming: IncomingDownload(url: URL(string: "https://www.youtube.com/@x")!), name: "", category: "General", kind: .file),
        MakeRow(label: "quality ignored elsewhere (guard)", incoming: IncomingDownload(url: URL(string: "https://h/a.zip")!, quality: "720"), name: "a.zip", category: "Compressed", kind: .file),
    ])
    func t15_01_makeItemRules(row: MakeRow) {
        let (library, _) = makeLibrary()
        library.settings.webVideoQuality = row.settingsQuality
        let item = library.makeItem(from: row.incoming, folder: row.folder)
        if let name = row.name { #expect(item.fileName == name) }
        let category = library.categories.first { $0.id == item.categoryID }
        #expect(category?.name == row.category)
        #expect(item.directory == (row.folder ?? category?.folder))
        if let kind = row.kind {
            #expect(item.kind == kind)
        } else {
            #expect((item.kind != .file) == row.hls)
        }
    }

    @Test func t17_11_youTubeItemsKeepTheSignIn() {
        let (library, _) = makeLibrary()
        let item = library.makeItem(from: IncomingDownload(url: URL(string: Self.watch)!, cookies: "SID=1", kind: "youtube"), folder: nil)
        #expect(item.cookies == "SID=1")
        #expect(item.kind == .webVideo(quality: .best))
    }

    @Test func t15_01_sanitizesNamesAndCopiesHeaders() {
        let (library, _) = makeLibrary()
        let incoming = IncomingDownload(url: URL(string: "https://h/x")!, referer: "https://h/page", fileName: "../x/a:b.pdf", cookies: "c=1", userAgent: "UA")
        let item = library.makeItem(from: incoming, folder: nil)
        #expect(!item.fileName.contains("/") && !item.fileName.contains(".."))
        #expect(item.fileName.hasSuffix(".pdf"))
        #expect(item.referer == "https://h/page" && item.cookies == "c=1" && item.userAgent == "UA")
        let plain = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/a.zip")!), folder: nil)
        #expect(plain.referer == nil && plain.cookies == nil && plain.userAgent == nil)
        #expect(plain.kind == .file)
    }

    // MARK: T15-02

    func serve(_ count: Int = 1, size: Int = 50_000, rate: Int? = nil) throws -> (LocalHTTPServer, [URL]) {
        let server = try LocalHTTPServer()
        bag.servers.append(server)
        let urls = (0..<count).map { index -> URL in
            var resource = LocalHTTPServer.Resource(body: Data.pattern(count: size, seed: UInt32(index + 1)))
            resource.bytesPerSecond = rate
            server.set("/f\(index).bin", resource)
            return server.url("/f\(index).bin")
        }
        return (server, urls)
    }

    func addRequest(_ urls: [URL], configure: (inout IPCRequest) -> Void = { _ in }) -> IPCRequest {
        var request = IPCRequest(type: .add, downloads: urls.map { IncomingDownload(url: $0) })
        configure(&request)
        return request
    }

    @Test func t15_02_pingConfigAndShowWindow() async {
        let (library, hooks) = makeLibrary()
        #expect(await library.handle(IPCRequest(type: .ping)).ok)
        library.settings.browserIntegration = false
        let config = await library.handle(IPCRequest(type: .getConfig)).config
        #expect(config == BrowserConfig(settings: library.settings))
        #expect(config?.integrationEnabled == false)
        // T17-10: the add-on learns the default YouTube quality.
        library.settings.webVideoQuality = .p480
        #expect(await library.handle(IPCRequest(type: .getConfig)).config?.webVideoQuality == "480")
        #expect(await library.handle(IPCRequest(type: .showWindow)).ok)
        #expect(hooks.showWindow == 1)
        #expect(library.items.isEmpty)
    }

    @Test func t15_02_silentAddsAndStarts() async throws {
        let (library, hooks) = makeLibrary()
        let (_, urls) = try serve()
        let reply = await library.handle(addRequest(urls) { $0.silent = true })
        #expect(reply.ok)
        #expect(library.items.count == 1)
        #expect(library.items.first?.status != .stopped)
        #expect(hooks.confirmations.isEmpty && hooks.selections.isEmpty)
        try await waitFor { library.items.first?.status == .completed }
    }

    @Test func t15_02_addOnlyQueuesWithoutStarting() async throws {
        let (library, hooks) = makeLibrary()
        let (_, urls) = try serve()
        _ = await library.handle(addRequest(urls) { $0.addOnly = true })
        let item = try #require(library.items.first)
        #expect(item.status == .stopped)
        #expect(library.queues.first { $0.id == DownloadQueue.mainDownloadID }?.itemIDs == [item.id])
        #expect(hooks.confirmations.isEmpty)
    }

    @Test func t15_02_listsAndSingleDownloadsGoThroughHooks() async throws {
        let (library, hooks) = makeLibrary()
        let (_, urls) = try serve(3)
        _ = await library.handle(addRequest([urls[0]]) { $0.showList = true })
        _ = await library.handle(addRequest(urls))
        #expect(hooks.selections.map(\.count) == [1, 3])
        library.settings.showStartDialog = true
        _ = await library.handle(addRequest([urls[0]]))
        #expect(hooks.confirmations.count == 1)
        #expect(library.items.isEmpty)

        library.settings.showStartDialog = false
        _ = await library.handle(addRequest([urls[1]]))
        #expect(library.items.count == 1)
        #expect(library.items.first?.status != .stopped)
    }

    @Test func t15_02_silentWinsOverAddOnlyAndBadInputIsRefused() async throws {
        let (library, _) = makeLibrary()
        let (_, urls) = try serve()
        _ = await library.handle(addRequest(urls) {
            $0.silent = true
            $0.addOnly = true
        })
        #expect(library.items.first?.status != .stopped)
        let bad = await library.handle(addRequest([URL(string: "mailto:x@y.z")!]) { $0.silent = true })
        #expect(!bad.ok)
        #expect(library.items.count == 1)
    }

    @Test func t15_02_startQueueStartsMainQueue() async throws {
        let (library, _) = makeLibrary()
        let (_, urls) = try serve(2)
        _ = await library.handle(addRequest(urls) { $0.addOnly = true })
        _ = await library.handle(IPCRequest(type: .startQueue))
        try await waitFor { library.items.allSatisfy { $0.status == .completed } }
        #expect(library.queues.first { $0.id == DownloadQueue.mainDownloadID }?.itemIDs.isEmpty == true)
    }

    // MARK: T15-03

    @Test func t15_03_quitAfterFiresOnce() async throws {
        let (library, hooks) = makeLibrary()
        let (_, urls) = try serve(2)
        _ = await library.handle(addRequest([urls[0]]) {
            $0.silent = true
            $0.quitAfter = true
        })
        try await waitFor { library.items.first?.status == .completed }
        try await waitFor { hooks.quitRequests == 1 }
        _ = await library.handle(addRequest([urls[1]]) { $0.silent = true })
        try await waitFor { library.items.count == 2 && library.items.allSatisfy { $0.status == .completed } }
        #expect(hooks.quitRequests == 1)

        let (_, missing) = (0, [URL(string: "http://127.0.0.1:9/nothing.bin")!])
        _ = await library.handle(addRequest(missing) {
            $0.silent = true
            $0.quitAfter = true
        })
        try await waitFor { library.items.last?.status == .failed }
        #expect(hooks.quitRequests == 1)
    }

    // MARK: T15-04

    @Test func t15_04_addressRefreshUpdatesTheWaitingItem() async throws {
        let (library, _) = makeLibrary()
        var old = library.makeItem(from: IncomingDownload(url: URL(string: "https://old.example/a.zip")!), folder: nil)
        old.segments = [SegmentRecord(start: 0, end: 100, downloaded: 40)]
        old.downloadedBytes = 40
        old.totalBytes = 100
        library.add(old, start: false)
        library.requestAddressRefresh(old.id)

        _ = await library.handle(addRequest([URL(string: "https://new.example/x/a.zip?sig=2")!]) { $0.addOnly = true })
        #expect(library.items.count == 1)
        let refreshed = try #require(library.item(old.id))
        #expect(refreshed.url.absoluteString == "https://new.example/x/a.zip?sig=2")
        #expect(refreshed.segments == old.segments && refreshed.downloadedBytes == 40)
        #expect(!refreshed.awaitingAddressRefresh)

        _ = await library.handle(addRequest([URL(string: "https://new.example/x/a.zip?sig=3")!]) { $0.addOnly = true })
        #expect(library.items.count == 2, "the flag is cleared, so the next one is a new item")
        _ = await library.handle(addRequest([URL(string: "https://new.example/b.zip")!]) { $0.addOnly = true })
        #expect(library.items.count == 3)
    }

    // MARK: T15-05

    @Test func t15_05_endToEndDownloadCompletesAndFiresHook() async throws {
        let (library, hooks) = makeLibrary()
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 300_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.contentDisposition = "attachment; filename=\"named.bin\""
        server.set("/f", resource)
        let item = library.makeItem(from: IncomingDownload(url: server.url("/f")), folder: downloads.url.path)
        #expect(item.fileName == "")
        library.add(item, start: true)
        try await waitFor { library.item(item.id)?.status == .completed }
        let done = try #require(library.item(item.id))
        #expect(done.fileName == "named.bin")
        #expect(try Data(contentsOf: done.destinationURL) == body)
        #expect(library.progress[item.id] == nil)
        #expect(hooks.completed.map(\.id) == [item.id])
    }

    @Test func t15_05_failureAndPauseResume() async throws {
        let (library, hooks) = makeLibrary()
        let server = try LocalHTTPServer()
        let missing = library.makeItem(from: IncomingDownload(url: server.url("/missing.bin")), folder: nil)
        library.add(missing, start: true)
        try await waitFor { library.item(missing.id)?.status == .failed }
        #expect(library.item(missing.id)?.errorMessage?.isEmpty == false)
        #expect(hooks.completed.isEmpty)

        var resource = LocalHTTPServer.Resource(body: Data.pattern(count: 800_000))
        resource.bytesPerSecond = 400_000
        server.set("/slow.bin", resource)
        let slow = library.makeItem(from: IncomingDownload(url: server.url("/slow.bin")), folder: nil)
        library.add(slow, start: true)
        try await waitFor { (library.progress[slow.id]?.downloadedBytes ?? 0) > 50_000 }
        library.pause(slow.id)
        try await waitFor { library.item(slow.id)?.status == .stopped }
        #expect((library.item(slow.id)?.downloadedBytes ?? 0) > 0)
        server.update("/slow.bin") { $0.bytesPerSecond = nil }
        library.start(slow.id)
        try await waitFor { library.item(slow.id)?.status == .completed }

        var other = LocalHTTPServer.Resource(body: Data.pattern(count: 800_000))
        other.bytesPerSecond = 100_000
        server.set("/a.bin", other)
        server.set("/b.bin", other)
        for path in ["/a.bin", "/b.bin"] {
            library.add(library.makeItem(from: IncomingDownload(url: server.url(path)), folder: nil), start: true)
        }
        try await waitFor { library.items.filter { $0.status == .downloading }.count == 2 }
        library.stopAll()
        try await waitFor { !library.items.contains { $0.status == .downloading } }
    }

    // MARK: T15-06

    @Test func t15_06_persistenceAndStartupRecovery() throws {
        var statuses: [DownloadStatus: UUID] = [:]
        do {
            let (library, _) = makeLibrary()
            for status in DownloadStatus.allCases {
                var item = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/\(status.rawValue).zip")!), folder: nil)
                item.status = status
                item.segments = [SegmentRecord(start: 0, end: 10, downloaded: 3)]
                library.add(item, start: false)
                statuses[status] = item.id
            }
            library.addCategory(DownloadCategory(id: "img", name: "Images", extensions: ["png"], folder: "/tmp/img"))
            library.addQueue(name: "Night", kind: .synchronization)
            library.flush()
        }
        let (reloaded, _) = makeLibrary()
        #expect(reloaded.items.count == DownloadStatus.allCases.count)
        #expect(reloaded.item(statuses[.downloading]!)?.status == .stopped)
        #expect(reloaded.item(statuses[.waiting]!)?.status == .stopped)
        #expect(reloaded.item(statuses[.completed]!)?.status == .completed)
        #expect(reloaded.item(statuses[.failed]!)?.status == .failed)
        #expect(reloaded.item(statuses[.stopped]!)?.segments.first?.downloaded == 3)
        #expect(reloaded.categories.contains { $0.name == "Images" })
        #expect(reloaded.queues.contains { $0.name == "Night" && $0.kind == .synchronization })
    }

    @Test func t15_06_missingAndCorruptFilesGiveDefaults() throws {
        let (fresh, _) = makeLibrary()
        #expect(fresh.queues.map(\.id).starts(with: [DownloadQueue.mainDownloadID, DownloadQueue.mainSyncID]))
        #expect(fresh.categories.count == 6)
        try Data("{broken".utf8).write(to: store.url.appendingPathComponent("library.json"))
        let (recovered, _) = makeLibrary()
        #expect(recovered.items.isEmpty && recovered.categories.count == 6)
        #expect(FileManager.default.fileExists(atPath: store.url.appendingPathComponent("library.json.corrupt-1").path))
    }

    @Test func t15_06_savesAreDebounced() {
        let (library, _) = makeLibrary()
        let before = library.saveCount
        for index in 0..<5 {
            library.add(library.makeItem(from: IncomingDownload(url: URL(string: "https://h/\(index).zip")!), folder: nil), start: false)
            library.tick()
        }
        #expect(library.saveCount == before)
        clock.advance(1.5)
        library.tick()
        #expect(library.saveCount == before + 1)
        library.tick()
        #expect(library.saveCount == before + 1)
    }

    // MARK: T17-12

    struct PlaylistRow: Sendable, CustomTestStringConvertible {
        var label: String
        var mode: String
        var cookies: String?
        var browser: String?
        var missingTool = false
        /// Titles of the items offered; nil when the playlist stays one item.
        var expectedTitles: [String]?
        var testDescription: String { label }
    }

    nonisolated static let playlistURL = "https://www.youtube.com/playlist?list=PLabc_12-x"

    @Test(arguments: [
        PlaylistRow(label: "playlist becomes its videos", mode: "playlist", expectedTitles: ["First: one/two", "Second"]),
        PlaylistRow(label: "sign-in from the add-on", mode: "playlist", cookies: "SID=SECRETVAL123", expectedTitles: ["First: one/two", "Second"]),
        PlaylistRow(label: "browser setting", mode: "playlist", browser: "chrome", expectedTitles: ["First: one/two", "Second"]),
        PlaylistRow(label: "add-on sign-in wins over the browser", mode: "playlist", cookies: "SID=SECRETVAL123", browser: "chrome", expectedTitles: ["First: one/two", "Second"]),
        PlaylistRow(label: "listing fails", mode: "fail"),
        PlaylistRow(label: "empty playlist", mode: "playlistempty"),
        PlaylistRow(label: "tool not installed", mode: "playlist", missingTool: true),
    ])
    func t17_12_playlistLinksOfferEveryVideo(row: PlaylistRow) async throws {
        let fake = try FakeYtDlp(mode: row.mode)
        let missing = store.url.appendingPathComponent("nowhere/yt-dlp").path
        let (library, hooks) = makeLibrary { $0.ytDlpPath = row.missingTool ? missing : fake.path }
        library.settings.webVideoCookiesBrowser = row.browser
        library.settings.showStartDialog = true
        var request = IPCRequest(type: .add, downloads: [IncomingDownload(url: URL(string: Self.playlistURL)!, cookies: row.cookies, kind: "youtube", quality: "720")])
        request.pageURL = Self.playlistURL
        let reply = await library.handle(request)
        #expect(reply.ok, "the browser gets its answer before the list is read")

        if let titles = row.expectedTitles {
            try await waitFor { hooks.selections.count == 1 }
            let offered = hooks.selections[0]
            #expect(offered.map(\.fileName) == titles.map(FileNameResolver.sanitize))
            #expect(offered.map(\.url.absoluteString) == ["aaaaaaaaaaa", "bbbbbbbbbbb"].map { "https://www.youtube.com/watch?v=\($0)" })
            #expect(offered.allSatisfy { $0.kind == .webVideo(quality: .p720) && $0.cookies == row.cookies })
            let arguments = fake.arguments
            #expect(Array(arguments.prefix(4)) == ["--ignore-config", "--flat-playlist", "--print", "%(id)s\t%(title)s"])
            #expect(Array(arguments.suffix(2)) == ["--", Self.playlistURL])
            if row.cookies != nil {
                #expect(arguments.contains("--cookies") && !arguments.contains("--cookies-from-browser"))
                #expect(fake.recorded("cookies-seen.txt") == YtDlp.cookieFile(header: row.cookies))
                #expect(fake.recorded("cookies-mode.txt") == "600")
                let cookieFile = try #require(arguments.firstIndex(of: "--cookies").map { arguments[$0 + 1] })
                #expect(!FileManager.default.fileExists(atPath: cookieFile), "the sign-in file is deleted after the listing")
            } else if let browser = row.browser {
                #expect(arguments.contains("--cookies-from-browser") && arguments.contains(browser))
            } else {
                #expect(!arguments.contains("--cookies") && !arguments.contains("--cookies-from-browser"))
            }
            #expect(!arguments.contains { $0.contains("SECRETVAL123") })
        } else {
            try await waitFor { hooks.confirmations.count == 1 }
            let kept = hooks.confirmations[0]
            #expect(kept.url.absoluteString == Self.playlistURL)
            #expect(kept.kind == .webVideo(quality: .p720))
            #expect(!kept.descriptionText.isEmpty, "the reason the list could not be read is kept")
            #expect(hooks.selections.isEmpty)
        }
    }

    @Test func t17_12_silentPlaylistAddsAndStartsEveryVideo() async throws {
        let fake = try FakeYtDlp(mode: "playlist")
        let (library, hooks) = makeLibrary { $0.ytDlpPath = fake.path }
        var request = IPCRequest(type: .add, downloads: [IncomingDownload(url: URL(string: Self.playlistURL)!)])
        request.silent = true
        #expect(await library.handle(request).ok)
        try await waitFor { library.items.count == 2 }
        #expect(hooks.selections.isEmpty && hooks.confirmations.isEmpty)
    }

    @Test func t17_12_singleVideoLinksAreNotListed() async throws {
        let fake = try FakeYtDlp(mode: "playlist")
        let (library, hooks) = makeLibrary { $0.ytDlpPath = fake.path }
        library.settings.showStartDialog = true
        #expect(await library.handle(IPCRequest(type: .add, downloads: [IncomingDownload(url: URL(string: Self.watch)!)])).ok)
        #expect(hooks.confirmations.count == 1, "a single video goes straight to the usual dialog")
        #expect(!fake.launched)
    }

    @Test func t17_12_appAddFlowExpandsPlaylistsToo() async throws {
        let fake = try FakeYtDlp(mode: "playlist")
        let (library, _) = makeLibrary { $0.ytDlpPath = fake.path }
        let items = await library.makeItemsExpandingPlaylists([IncomingDownload(url: URL(string: Self.playlistURL)!)], folder: nil)
        #expect(items.count == 2)
        let single = await library.makeItemsExpandingPlaylists([IncomingDownload(url: URL(string: "https://h/a.zip")!)], folder: nil)
        #expect(single.count == 1 && single[0].kind == .file)
    }

    /// T17-CR03: removing a running YouTube download leaves no work folder once the tool has stopped.
    @Test func t17_cr03_removingARunningVideoLeavesNoWorkFolder() async throws {
        let fake = try FakeYtDlp(mode: "slowtrap")
        let (library, _) = makeLibrary { $0.ytDlpPath = fake.path }
        let item = library.makeItem(from: IncomingDownload(url: URL(string: Self.watch)!), folder: downloads.url.path)
        library.add(item, start: true)
        try await waitFor { library.progress[item.id] != nil }
        let workFolder = library.engine.currentConfiguration.temporaryDirectory.appendingPathComponent("\(item.id.uuidString).ytdlp", isDirectory: true)
        library.remove([item.id], deleteFiles: false)
        try await waitFor { fake.recorded("trapped") != nil }
        try await waitFor { !FileManager.default.fileExists(atPath: workFolder.path) }
    }

    /// T17-CR04: a sign-in file left behind by a crash or a quit is deleted at the next launch.
    @Test func t17_cr04_leftoverSignInsAreDeletedAtLaunch() throws {
        let temp = store.url.appendingPathComponent("Temp", isDirectory: true)
        let work = temp.appendingPathComponent("\(UUID().uuidString).ytdlp", isDirectory: true)
        let listing = temp.appendingPathComponent("playlist-\(UUID().uuidString)", isDirectory: true)
        for folder in [work, listing] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("c".utf8).write(to: work.appendingPathComponent("cookies.txt"))
        try Data("p".utf8).write(to: work.appendingPathComponent("v.mp4.part"))
        try Data("c".utf8).write(to: listing.appendingPathComponent("cookies.txt"))
        _ = makeLibrary()
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("cookies.txt").path))
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("v.mp4.part").path), "the partial download stays for resuming")
        #expect(!FileManager.default.fileExists(atPath: listing.path))
    }

    /// T17-CR06: a playlist listing that hangs gives up, and the link stays as one item that says why.
    @Test func t17_cr06_hangingPlaylistListingGivesUp() async throws {
        let fake = try FakeYtDlp(mode: "hang")
        let (library, hooks) = makeLibrary {
            $0.ytDlpPath = fake.path
            $0.playlistTimeout = 0.5
            $0.toolStopGrace = 0.3
        }
        library.settings.showStartDialog = true
        #expect(await library.handle(IPCRequest(type: .add, downloads: [IncomingDownload(url: URL(string: Self.playlistURL)!)])).ok)
        try await waitFor(8) { hooks.confirmations.count == 1 }
        #expect(hooks.confirmations[0].descriptionText.contains("took too long"))
    }

    // MARK: T17-18

    @Test func t17_18_botCheckReachesTheList() async throws {
        let fake = try FakeYtDlp(mode: "bot")
        let (library, _) = makeLibrary { $0.ytDlpPath = fake.path }
        let item = library.makeItem(from: IncomingDownload(url: URL(string: Self.watch)!), folder: downloads.url.path)
        library.add(item, start: true)
        try await waitFor { library.item(item.id)?.status == .failed }
        #expect(library.item(item.id)?.errorMessage == YtDlp.botCheckMessage)
    }

    // MARK: T15-07

    @Test func t15_07_removeAndCleanup() async throws {
        let (library, _) = makeLibrary()
        let tempDirectory = library.engine.currentConfiguration.temporaryDirectory
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        var partial = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/p.zip")!), folder: downloads.url.path)
        partial.downloadedBytes = 5
        let partialFile = tempDirectory.appendingPathComponent("\(partial.id.uuidString).part")
        try Data(count: 5).write(to: partialFile)
        var keep = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/k.zip")!), folder: downloads.url.path)
        keep.status = .completed
        try Data("k".utf8).write(to: keep.destinationURL)
        var gone = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/g.zip")!), folder: downloads.url.path)
        gone.status = .completed
        try Data("g".utf8).write(to: gone.destinationURL)
        var missingFile = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/m.zip")!), folder: downloads.url.path)
        missingFile.status = .completed
        for item in [partial, keep, gone, missingFile] { library.add(item, start: false, queueID: DownloadQueue.mainDownloadID) }

        library.remove([partial.id], deleteFiles: false)
        #expect(library.item(partial.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: partialFile.path))
        // T17-12: a YouTube download's work folder (with a sign-in file) goes too.
        let video = library.makeItem(from: IncomingDownload(url: URL(string: Self.watch)!), folder: downloads.url.path)
        let workFolder = tempDirectory.appendingPathComponent("\(video.id.uuidString).ytdlp", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: workFolder.appendingPathComponent("v.mp4.part"))
        try Data("c".utf8).write(to: workFolder.appendingPathComponent("cookies.txt"))
        library.add(video, start: false, queueID: DownloadQueue.mainDownloadID)
        library.remove([video.id], deleteFiles: false)
        #expect(!FileManager.default.fileExists(atPath: workFolder.path))
        library.remove([keep.id], deleteFiles: false)
        #expect(FileManager.default.fileExists(atPath: keep.destinationURL.path))
        library.remove([gone.id, missingFile.id], deleteFiles: true)
        #expect(!FileManager.default.fileExists(atPath: gone.destinationURL.path))
        #expect(library.items.isEmpty)
        #expect(library.queues.allSatisfy { $0.itemIDs.isEmpty })

        var done = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/d.zip")!), folder: nil)
        done.status = .completed
        library.add(done, start: false)
        library.add(library.makeItem(from: IncomingDownload(url: URL(string: "https://h/s.zip")!), folder: nil), start: false)
        library.removeCompleted()
        #expect(library.items.count == 1 && library.items.first?.status == .stopped)
    }

    @Test func t15_07_removingARunningDownloadStopsIt() async throws {
        let (library, _) = makeLibrary()
        let (server, urls) = try serve(1, size: 2_000_000, rate: 200_000)
        let item = library.makeItem(from: IncomingDownload(url: urls[0]), folder: downloads.url.path)
        library.add(item, start: true)
        try await waitFor { (library.progress[item.id]?.downloadedBytes ?? 0) > 20_000 }
        library.remove([item.id], deleteFiles: true)
        #expect(library.item(item.id) == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.item(item.id) == nil)
        #expect(!library.isRunning(item.id))
        _ = server
    }

    // MARK: T15-08

    @Test func t15_08_redownloadReplacesTheFileAndSpeedLimitsReachTheEngine() async throws {
        let (library, _) = makeLibrary()
        let server = try LocalHTTPServer()
        server.set("/r.bin", .init(body: Data.pattern(count: 100_000, seed: 1)))
        let item = library.makeItem(from: IncomingDownload(url: server.url("/r.bin")), folder: downloads.url.path)
        library.add(item, start: true)
        try await waitFor { library.item(item.id)?.status == .completed }
        let path = try #require(library.item(item.id)).destinationURL

        let changed = Data.pattern(count: 120_000, seed: 2)
        server.set("/r.bin", .init(body: changed))
        library.redownload(item.id)
        let restarted = library.item(item.id)
        #expect(restarted?.downloadedBytes == 0 || restarted?.status == .downloading)
        try await waitFor { library.item(item.id)?.status == .completed && library.item(item.id)?.downloadedBytes == 120_000 }
        #expect(try Data(contentsOf: path) == changed)
        #expect(library.item(item.id)?.destinationURL == path)

        library.setSpeedLimit(item.id, bytesPerSecond: 500_000)
        #expect(library.item(item.id)?.speedLimit == 500_000)
        #expect(library.engine.limiter.limit(for: item.id) == 500_000)
        library.setSpeedLimit(item.id, bytesPerSecond: nil)
        #expect(library.engine.limiter.limit(for: item.id) == nil)
    }

    // MARK: T15-09

    @Test(arguments: [1, 8, 16])
    func t15_09_settingsReachEngineAndDisk(connections: Int) throws {
        let secrets = InMemorySecretStore()
        do {
            let (library, _) = makeLibrary(secrets: secrets)
            library.settings.maxConnections = connections
            #expect(library.engine.currentConfiguration.maxConnections == connections)
            library.settings.speedLimiter.enabled = true
            library.settings.speedLimiter.bytesPerSecond = 300_000
            #expect(library.engine.limiter.globalLimit == 300_000)
            library.settings.speedLimiter.bytesPerSecond = 0
            #expect(library.engine.limiter.globalLimit == nil)
            let login = SiteLogin(urlPrefix: "https://h/", username: "u")
            secrets.setPassword("pw-secret", for: login.credentialKey)
            library.settings.siteLogins = [login]
        }
        let (reloaded, _) = makeLibrary(secrets: secrets)
        #expect(reloaded.settings.maxConnections == connections)
        let raw = try String(contentsOf: store.url.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(!raw.contains("pw-secret"))
    }

    // MARK: T15-10

    @Test func t15_10_queueWiring() async throws {
        let (library, _) = makeLibrary()
        let custom = library.addQueue(name: "X", kind: .download)
        #expect(library.queues.contains { $0.id == custom.id })
        library.deleteQueue(DownloadQueue.mainDownloadID)
        library.deleteQueue(DownloadQueue.mainSyncID)
        #expect(library.queues.contains { $0.id == DownloadQueue.mainDownloadID })
        #expect(library.queues.contains { $0.id == DownloadQueue.mainSyncID })

        let a = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/a.zip")!), folder: nil)
        let b = library.makeItem(from: IncomingDownload(url: URL(string: "https://h/b.zip")!), folder: nil)
        library.add(a, start: false)
        library.add(b, start: false, queueID: custom.id)
        #expect(library.queues.first { $0.id == DownloadQueue.mainDownloadID }?.itemIDs == [a.id])
        #expect(library.queues.first { $0.id == custom.id }?.itemIDs == [b.id])

        library.moveItems([b.id, a.id, UUID()], toQueue: DownloadQueue.mainDownloadID)
        #expect(library.queues.first { $0.id == DownloadQueue.mainDownloadID }?.itemIDs == [b.id, a.id])
        #expect(library.queues.first { $0.id == custom.id }?.itemIDs.isEmpty == true)

        library.moveItems([a.id], toQueue: custom.id)
        library.deleteQueue(custom.id)
        #expect(!library.queues.contains { $0.id == custom.id })
        #expect(library.item(a.id)?.queueID == nil)
        #expect(library.item(a.id) != nil)

        library.startQueue(DownloadQueue.mainSyncID)
        #expect(!library.isQueueRunning(DownloadQueue.mainSyncID), "an empty queue finishes at once")
    }
}
