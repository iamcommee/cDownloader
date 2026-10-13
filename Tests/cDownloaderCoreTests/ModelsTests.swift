import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct ModelsTests {
    struct Doc: Codable, Sendable, Equatable {
        var name: String
        var value: Double
    }

    @Test func t2_01_roundTripKeepsValuesAndKeepsPasswordsOutOfJSON() throws {
        let dir = TempDir()
        let secrets = InMemorySecretStore()

        var item = DownloadItem(url: URL(string: "https://h.example/a.zip")!, fileName: "a.zip", directory: dir.url.path, dateAdded: Date(timeIntervalSince1970: 1000))
        item.segments = [SegmentRecord(start: 0, end: 500, downloaded: 120), SegmentRecord(start: 500, end: 1000, downloaded: 7)]
        item.totalBytes = 1000
        item.downloadedBytes = 127
        item.username = "bob"
        item.etag = "\"v1\""
        item.kind = .hls(variantIndex: 2)
        item.status = .failed
        item.errorMessage = "Timed out"
        secrets.setPassword("s3cret-download", for: item.credentialKey)

        var schedule = QueueSchedule(startEnabled: true, startTime: TimeOfDay(hour: 2, minute: 30), repeatRule: .weekdays([2, 4]))
        schedule.stopEnabled = true
        let queue = DownloadQueue(name: "Night", kind: .synchronization, concurrentDownloads: 3, itemIDs: [item.id], schedule: schedule, maxRetries: 4, postAction: .shutDown(force: false))

        var settings = AppSettings()
        let login = SiteLogin(urlPrefix: "https://h.example/private/", username: "alice")
        settings.siteLogins = [login]
        settings.proxy.mode = .manual
        settings.proxy.username = "proxyuser"
        settings.connectionExceptions = [ConnectionException(hostPattern: "*.slow.com", maxConnections: 1)]
        // T17-10: the YouTube settings survive a save.
        settings.webVideoQuality = .p720
        settings.webVideoCookiesBrowser = "chrome"
        secrets.setPassword("s3cret-site", for: login.credentialKey)
        secrets.setPassword("s3cret-proxy", for: ProxySettings.credentialKey)

        var video = DownloadItem(url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, fileName: "", directory: dir.url.path, dateAdded: Date(timeIntervalSince1970: 2000))
        video.kind = .webVideo(quality: .audio)
        let library = LibraryState(downloads: [item, video], queues: DownloadQueue.defaults() + [queue], categories: CategoryCatalog.defaults(root: dir.url))
        let libraryStore = JSONStore(fileURL: dir.file("library.json"), defaultValue: { LibraryState() })
        let settingsStore = JSONStore(fileURL: dir.file("settings.json"), defaultValue: { AppSettings() })
        try libraryStore.save(library)
        try settingsStore.save(settings)

        #expect(libraryStore.load() == library)
        #expect(settingsStore.load() == settings)
        for name in ["library.json", "settings.json"] {
            let raw = try String(contentsOf: dir.file(name), encoding: .utf8)
            #expect(!raw.contains("s3cret"), "\(name) must not contain passwords")
        }
        #expect(secrets.password(for: item.credentialKey) == "s3cret-download")
        #expect(secrets.password(for: login.credentialKey) == "s3cret-site")
    }

    @Test func t2_02_failedSaveKeepsOldFile() throws {
        let dir = TempDir()
        let store = JSONStore(fileURL: dir.file("doc.json"), defaultValue: { Doc(name: "default", value: 0) })
        let good = Doc(name: "good", value: 1)
        try store.save(good)
        #expect(throws: (any Error).self) { try store.save(Doc(name: "bad", value: .nan)) }
        #expect(store.load() == good)
    }

    @Test func t2_02_corruptFileIsBackedUpAndDefaultsReturned() throws {
        let dir = TempDir()
        let url = dir.file("doc.json")
        let store = JSONStore(fileURL: url, defaultValue: { Doc(name: "default", value: 0) })

        try Data("{ not json".utf8).write(to: url)
        #expect(store.load() == Doc(name: "default", value: 0))
        let firstBackup = try #require(store.lastBackupURL)
        #expect(firstBackup.lastPathComponent == "doc.json.corrupt-1")
        #expect(try String(contentsOf: firstBackup, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try Data("{\"name\": 5".utf8).write(to: url)
        _ = store.load()
        #expect(store.lastBackupURL?.lastPathComponent == "doc.json.corrupt-2")
    }

    @Test func t2_02_missingFileGivesDefaults() {
        let dir = TempDir()
        let store = JSONStore(fileURL: dir.file("absent.json"), defaultValue: { Doc(name: "default", value: 0) })
        #expect(store.load() == Doc(name: "default", value: 0))
        #expect(store.lastBackupURL == nil)
    }

    @Test func t2_02_olderSettingsFileWithMissingKeysLoads() throws {
        let dir = TempDir()
        let url = dir.file("settings.json")
        try Data("{\"maxConnections\": 3}".utf8).write(to: url)
        let store = JSONStore(fileURL: url, defaultValue: { AppSettings() })
        let loaded = store.load()
        #expect(loaded.maxConnections == 3)
        #expect(loaded.capturedExtensions == AppSettings.defaultCapturedExtensions)
        #expect(loaded.webVideoQuality == .best)
        #expect(loaded.webVideoCookiesBrowser == nil)
        #expect(store.lastBackupURL == nil)
    }

    // MARK: T17-10

    @Test func t17_10_downloadKindsDecodeOldAndNewForms() throws {
        func kind(_ json: String) throws -> DownloadKind {
            let text = "{\"id\":\"\(UUID().uuidString)\",\"url\":\"https://h/x\",\"fileName\":\"\",\"directory\":\"/d\",\"kind\":\(json)}"
            return try JSONDecoder().decode(DownloadItem.self, from: Data(text.utf8)).kind
        }
        // Items saved before this change (guard).
        #expect(try kind("{\"file\":{}}") == .file)
        #expect(try kind("{\"hls\":{\"variantIndex\":2}}") == .hls(variantIndex: 2))
        #expect(try kind("{\"hls\":{}}") == .hls(variantIndex: nil))
        // Every quality is saved under a stable name and comes back unchanged.
        #expect(VideoQuality.allCases.map(\.rawValue) == ["best", "1080", "720", "480", "360", "audio"])
        for quality in VideoQuality.allCases {
            var item = DownloadItem(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, fileName: "", directory: "/d")
            item.kind = .webVideo(quality: quality)
            let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
            #expect(back.kind == .webVideo(quality: quality))
        }
        #expect(try kind("{\"webVideo\":{\"quality\":\"1080\"}}") == .webVideo(quality: .p1080))
        // A quality this version does not know falls back to the best one instead of losing the list.
        #expect(try kind("{\"webVideo\":{\"quality\":\"4k\"}}") == .webVideo(quality: .best))
    }

    @Test func t17_10_incomingDownloadQualityIsOptional() throws {
        let old = try JSONDecoder().decode(IncomingDownload.self, from: Data("{\"url\":\"https://h/x\",\"cookies\":\"a=1\"}".utf8))
        #expect(old.quality == nil && old.cookies == "a=1")
        let new = try JSONDecoder().decode(IncomingDownload.self, from: Data("{\"url\":\"https://h/x\",\"quality\":\"720\"}".utf8))
        #expect(new.quality == "720")
    }

    struct CategoryRow: Sendable, CustomTestStringConvertible {
        var label: String
        var fileName: String
        var expected: String
        var testDescription: String { label }
    }

    @Test(arguments: [
        CategoryRow(label: "lower zip", fileName: "a.zip", expected: "Compressed"),
        CategoryRow(label: "upper", fileName: "A.MP4", expected: "Video"),
        CategoryRow(label: "doc", fileName: "x.pdf", expected: "Documents"),
        CategoryRow(label: "music", fileName: "s.mp3", expected: "Music"),
        CategoryRow(label: "program", fileName: "i.dmg", expected: "Programs"),
        CategoryRow(label: "unknown", fileName: "x.xyz", expected: "General"),
        CategoryRow(label: "no ext", fileName: "README", expected: "General"),
        CategoryRow(label: "double ext", fileName: "a.tar.gz", expected: "Compressed"),
        CategoryRow(label: "wildcard ext", fileName: "part.r01", expected: "Compressed"),
    ])
    func t2_03_suggestsCategoryByExtension(row: CategoryRow) {
        let categories = CategoryCatalog.defaults(root: URL(fileURLWithPath: "/Users/x/Downloads"))
        #expect(CategoryCatalog.suggest(fileName: row.fileName, in: categories)?.name == row.expected)
    }

    @Test func t2_04_streamPlaylistsAreTakenOverByDefault() {
        #expect(AppSettings.defaultCapturedExtensions.contains("m3u8"))
    }

    @Test func t2_03_sixDefaultCategoriesWithFolders() throws {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let categories = CategoryCatalog.defaults(root: root)
        try #require(categories.map(\.name) == ["General", "Compressed", "Documents", "Music", "Programs", "Video"])
        #expect(categories.allSatisfy { $0.isBuiltIn && !$0.folder.isEmpty })
        #expect(categories.first?.id == DownloadCategory.generalID)
        #expect(categories.first?.folder == root.path)
        #expect(categories[1].folder == root.appendingPathComponent("Compressed").path)
    }
}
