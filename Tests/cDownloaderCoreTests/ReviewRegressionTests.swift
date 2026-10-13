import CommonCrypto
import Foundation
import Testing
@testable import cDownloaderCore

/// Regression tests written from the code review findings (CR-xx).
@Suite struct ReviewRegressionTests {
    let dir = TempDir()

    func makeEngine(_ configure: (inout EngineConfiguration) -> Void = { _ in }) -> DownloadEngine {
        var configuration = EngineConfiguration(temporaryDirectory: dir.url.appendingPathComponent("tmp", isDirectory: true))
        configuration.minSegmentSize = 32 * 1024
        configuration.retryDelay = 0.05
        configuration.checkpointInterval = 0.05
        configuration.timeout = 10
        configure(&configuration)
        return DownloadEngine(configuration: configuration, secrets: InMemorySecretStore())
    }

    func run(_ engine: DownloadEngine, _ item: DownloadItem) async throws -> DownloadItem {
        let recorder = JobRecorder()
        let runner = engine.makeRunner(for: item) { recorder.handle($0) }
        runner.start()
        return try await recorder.waitForFinish()
    }

    // MARK: CR-01 grabber paths stay inside the save folder

    @Test(arguments: [
        "http://h/a/..%2f..%2fLibrary/LaunchAgents/x.plist",
        "http://h/a/..%2f..%2fx.plist",
        "http://h/..%2F..%2F..%2Fetc/x.bin",
        "http://h/a/%2e%2e/%2e%2e/y.bin",
    ])
    func cr01_relativePathsCannotEscape(address: String) throws {
        let url = try #require(URL(string: address))
        let folder = dir.url.appendingPathComponent("grab", isDirectory: true)
        for subfolders in [true, false] {
            let relative = GrabberRules.relativePath(for: url, useOriginalSubfolders: subfolders)
            #expect(!relative.split(separator: "/").contains(".."), "\(relative)")
            let file = GrabberFile(url: url, referer: url, size: nil, contentType: nil, checked: true, relativePath: relative)
            let target = try #require(file.destination(in: folder))
            #expect(target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"))
        }
    }

    @Test func cr01_storedTraversalPathIsRefused() {
        let url = URL(string: "http://h/x.plist")!
        let folder = dir.url.appendingPathComponent("grab", isDirectory: true)
        let file = GrabberFile(url: url, referer: url, size: nil, contentType: nil, checked: true, relativePath: "../../Library/LaunchAgents/x.plist")
        #expect(file.destination(in: folder) == nil)
        let fine = GrabberFile(url: url, referer: url, size: nil, contentType: nil, checked: true, relativePath: "sub/x.plist")
        #expect(fine.destination(in: folder)?.path == folder.appendingPathComponent("sub/x.plist").path)
    }

    // MARK: CR-02 no FTP command injection

    @Test func cr02_lineBreaksInFTPAddressAreRefused() async throws {
        let server = try LocalFTPServer()
        server.setFile("/b.bin", Data(count: 10))
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = "127.0.0.1"
        components.port = Int(server.port)
        components.percentEncodedPath = "/a%0D%0ADELE%20b.bin"
        let url = try #require(components.url)
        let result = try await run(makeEngine(), DownloadItem(url: url, fileName: "a.bin", directory: dir.url.path))
        #expect(result.status == .failed)
        #expect(!server.commands.contains { $0.uppercased().hasPrefix("DELE") })
    }

    // MARK: CR-03 cookies and logins stay with their own site

    @Test func cr03_cookiesAndLoginDoNotFollowRedirectToAnotherSite() async throws {
        let origin = try LocalHTTPServer()
        let other = try LocalHTTPServer()
        var file = LocalHTTPServer.Resource(body: Data.pattern(count: 600_000))
        file.bytesPerSecond = 1_500_000
        other.set("/f.bin", file)
        var hop = LocalHTTPServer.Resource(body: Data())
        hop.redirectTo = other.url("/f.bin").absoluteString
        origin.set("/r", hop)

        let engine = makeEngine { $0.maxConnections = 3 }
        var item = DownloadItem(url: origin.url("/r"), fileName: "f.bin", directory: dir.url.path)
        item.cookies = "sid=secret"
        item.username = "u"
        engine.secrets.setPassword("pw", for: item.credentialKey)
        let result = try await run(engine, item)
        #expect(result.status == .completed)
        #expect(origin.requests(for: "/r").first?.headers["cookie"] == "sid=secret")
        let foreign = other.requests(for: "/f.bin")
        #expect(!foreign.isEmpty)
        #expect(foreign.allSatisfy { $0.headers["cookie"] == nil && $0.headers["authorization"] == nil })
    }

    struct SiteRow: Sendable, CustomTestStringConvertible {
        var label: String
        var from: String
        var to: String
        var shared: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        SiteRow(label: "same address", from: "https://h.example/a", to: "https://h.example/b", shared: true),
        SiteRow(label: "upgrade to https", from: "http://h.example/a", to: "https://h.example/a", shared: true),
        SiteRow(label: "upgrade with explicit ports", from: "http://h.example:80/a", to: "https://h.example:443/a", shared: true),
        SiteRow(label: "downgrade to http", from: "https://h.example/a", to: "http://h.example/a", shared: false),
        SiteRow(label: "other host", from: "https://h.example/a", to: "https://cdn.other/a", shared: false),
        SiteRow(label: "other port", from: "https://h.example/a", to: "https://h.example:8443/a", shared: false),
        SiteRow(label: "host case", from: "https://H.Example/a", to: "https://h.example/b", shared: true),
    ])
    func rr01_sameHostUpgradeKeepsCredentials(row: SiteRow) {
        #expect(URL(string: row.from)!.sharesCredentials(with: URL(string: row.to)!) == row.shared)
    }

    @Test func cr03_streamPiecesOnAnotherSiteGetNoCookies() async throws {
        let origin = try LocalHTTPServer()
        let other = try LocalHTTPServer()
        other.set("/s0.ts", .init(body: Data.pattern(count: 1000)))
        origin.set("/s1.ts", .init(body: Data.pattern(count: 1000, seed: 3)))
        let playlist = "#EXTM3U\n#EXTINF:4,\n\(other.url("/s0.ts").absoluteString)\n#EXTINF:4,\ns1.ts\n#EXT-X-ENDLIST\n"
        origin.set("/v.m3u8", .init(body: Data(playlist.utf8)))
        var item = DownloadItem(url: origin.url("/v.m3u8"), fileName: "", directory: dir.url.path)
        item.kind = .hls(variantIndex: nil)
        item.cookies = "sid=secret"
        let result = try await run(makeEngine(), item)
        #expect(result.status == .completed)
        #expect(origin.requests(for: "/v.m3u8").first?.headers["cookie"] == "sid=secret")
        #expect(origin.requests(for: "/s1.ts").first?.headers["cookie"] == "sid=secret")
        #expect(other.requests(for: "/s0.ts").first?.headers["cookie"] == nil)
    }

    // MARK: CR-05 a changed file is never stitched from the wrong offset

    @Test func cr05_serverIgnoringIfRangeWithNewSizeRestartsCleanly() async throws {
        let server = try LocalHTTPServer()
        var resource = LocalHTTPServer.Resource(body: Data.pattern(count: 1_000_000, seed: 1))
        resource.bytesPerSecond = 500_000
        resource.etag = "\"v1\""
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 2 }
        let recorder = JobRecorder()
        let job = engine.makeJob(for: DownloadItem(url: server.url("/f.bin"), fileName: "f.bin", directory: dir.url.path)) { recorder.handle($0) }
        job.start()
        try await recorder.waitUntil { recorder.downloaded >= 200_000 }
        job.pause()
        let paused = try await recorder.waitForFinish()

        let newBody = Data.pattern(count: 1_300_000, seed: 9)
        server.update("/f.bin") {
            $0.body = newBody
            $0.etag = "\"v2\""
            $0.ignoreIfRange = true
            $0.bytesPerSecond = nil
        }
        let result = try await run(engine, paused)
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == newBody)
    }

    // MARK: CR-06 and CR-07 hostile zip archives

    struct FakeFetcher: RangeFetching, @unchecked Sendable {
        let tail: Data
        let total: Int64?
        let log = RangeLog()

        func fetch(_ url: URL, range: String) async throws -> (data: Data, totalSize: Int64?) {
            log.add(range)
            if range.hasPrefix("-") { return (tail, total) }
            let parts = range.split(separator: "-")
            guard parts.count == 2, let start = UInt64(parts[0]), let end = UInt64(parts[1]), end >= start else { return (Data(), total) }
            return (Data(count: Int(min(end - start + 1, 1024))), total)
        }
    }

    final class RangeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ranges: [String] = []
        func add(_ range: String) { lock.withLock { ranges.append(range) } }
        var all: [String] { lock.withLock { ranges } }

        /// The longest byte count any request asked for.
        var longest: UInt64 {
            all.compactMap { range -> UInt64? in
                let parts = range.split(separator: "-")
                guard parts.count == 2, let start = UInt64(parts[0]), let end = UInt64(parts[1]) else { return nil }
                return end >= start ? end - start + 1 : nil
            }.max() ?? 0
        }
    }

    /// An end record claiming a directory of `size` bytes at `offset`.
    static func endRecord(count: UInt16 = 1, size: UInt32, offset: UInt32) -> Data {
        var data = Data()
        data.le32(0x0605_4B50); data.le16(0); data.le16(0); data.le16(count); data.le16(count)
        data.le32(size); data.le32(offset); data.le16(0)
        return data
    }

    @Test(arguments: [Int64(-1), Int64(5)])
    func cr06_badTotalsThrowInsteadOfCrashing(total: Int64) async {
        let fetcher = FakeFetcher(tail: Self.endRecord(size: 46, offset: 0), total: total)
        await #expect(throws: ZipPreviewError.self) { try await RemoteZipPreview(url: URL(string: "https://h/a.zip")!, fetcher: fetcher).listEntries() }
    }

    @Test func cr06_zip64LocatorNearTheTopThrows() async {
        var tail = Data()
        tail.le32(0x0706_4B50); tail.le32(0); tail.le64(UInt64.max - 5); tail.le32(1)
        tail.append(Self.endRecord(count: 0xFFFF, size: 0xFFFF_FFFF, offset: 0xFFFF_FFFF))
        let fetcher = FakeFetcher(tail: tail, total: Int64(tail.count))
        await #expect(throws: ZipPreviewError.self) { try await RemoteZipPreview(url: URL(string: "https://h/a.zip")!, fetcher: fetcher).listEntries() }
    }

    @Test func cr06_entryOffsetNearTheTopThrows() async {
        let fetcher = FakeFetcher(tail: Data(), total: 100)
        let entry = ZipEntry(name: "x", compressedSize: 10, uncompressedSize: 10, method: 0, crc32: 0, localHeaderOffset: UInt64.max - 10, isEncrypted: false)
        await #expect(throws: ZipPreviewError.self) { try await RemoteZipPreview(url: URL(string: "https://h/a.zip")!, fetcher: fetcher).extract(entry) }
    }

    @Test func cr07_hugeDirectoryIsRefusedWithoutDownloadingIt() async {
        let fetcher = FakeFetcher(tail: Self.endRecord(size: 0x7FFF_FFF0, offset: 0), total: 10_000_000_000)
        await #expect(throws: ZipPreviewError.tooLarge) { try await RemoteZipPreview(url: URL(string: "https://h/a.zip")!, fetcher: fetcher).listEntries() }
        #expect(fetcher.log.longest <= RemoteZipPreview.maxDirectoryBytes)
    }

    @Test func cr07_hugeOrLyingEntriesAreRefused() async throws {
        let huge = ZipEntry(name: "big", compressedSize: 6_000_000_000, uncompressedSize: 6_000_000_000, method: 0, crc32: 0, localHeaderOffset: 0, isEncrypted: false)
        let fetcher = FakeFetcher(tail: Data(), total: 7_000_000_000)
        await #expect(throws: ZipPreviewError.tooLarge) { try await RemoteZipPreview(url: URL(string: "https://h/a.zip")!, fetcher: fetcher).extract(huge) }

        // A small deflate stream that expands far beyond the size its header claims.
        var builder = TestZipBuilder()
        builder.entries = [.init(name: "bomb.bin", data: Data(count: 20_000_000), method: 8)]
        var archive = builder.build()
        let server = try LocalHTTPServer()
        server.set("/a.zip", .init(body: archive))
        let preview = RemoteZipPreview(url: server.url("/a.zip"))
        var entry = try #require(try await preview.listEntries().first)
        entry.uncompressedSize = 100
        await #expect(throws: ZipPreviewError.tooLarge) { try await preview.extract(entry) }
        archive.removeAll()
    }

    // MARK: CR-13 socket hardening

    @Test func cr13_longHomeFoldersUseThePrivateTemporaryFolder() {
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 120), isDirectory: true)
        let path = AppPaths.socketPath(for: long)
        #expect(path.hasPrefix(NSTemporaryDirectory()))
        #expect(path.utf8.count < 104)
        let short = URL(fileURLWithPath: "/Users/a/Library/Application Support/cDownloader", isDirectory: true)
        #expect(AppPaths.socketPath(for: short) == short.appendingPathComponent("ipc.sock").path)
    }

    @Test func cr13_endlessLineClosesTheConnectionAndServerKeepsWorking() throws {
        let path = "/tmp/cdl-\(UUID().uuidString.prefix(8)).sock"
        let server = IPCServer(socketPath: path) { _ in IPCReply(ok: true) }
        try server.start()
        defer { server.stop() }
        let flood = Data(repeating: UInt8(ascii: "a"), count: IPCServer.maxLineBytes + 1024)
        let started = Date()
        // The server hangs up (the client sees the connection end) instead of buffering forever.
        #expect(throws: IPCError.invalidReply) { try IPCClient.exchange(raw: flood, socketPath: path, replies: 1, timeout: 20) }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(try IPCClient.send(IPCRequest(type: .ping), socketPath: path).ok)
    }

    @Test func cr13_browserRequestsCannotSetCommandLineOptions() {
        var request = IPCRequest(type: .add, downloads: [IncomingDownload(url: URL(string: "https://h/a.zip")!)])
        request.folder = "/Users/x/Library/LaunchAgents"
        request.silent = true
        request.addOnly = true
        request.quitAfter = true
        request.showList = true
        let clean = request.sanitizedForBrowser()
        #expect(clean.folder == nil && clean.silent == nil && clean.addOnly == nil && clean.quitAfter == nil)
        #expect(clean.showList == true)
        #expect(clean.downloads == request.downloads)
    }

    // MARK: CR-14 empty files

    @Test func cr14_emptyFileCompletesEvenWhenServerRefusesTheRange() async throws {
        let server = try LocalHTTPServer()
        server.set("/empty.bin", .init(body: Data()))
        let result = try await run(makeEngine(), DownloadItem(url: server.url("/empty.bin"), fileName: "empty.bin", directory: dir.url.path))
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL).isEmpty)
    }
}

@MainActor
@Suite struct ReviewLibraryRegressionTests {
    let bag = ServerBag()
    let store = TempDir()
    let downloads = TempDir()

    // MARK: CR-04 removing a running download keeps its queue moving

    @Test func cr04_removingTheActiveDownloadStartsTheNextOne() async throws {
        let library = DownloadLibrary(storeDirectory: store.url, secrets: InMemorySecretStore(), downloadsRoot: downloads.url) { configuration in
            configuration.retryDelay = 0.05
            configuration.timeout = 10
        }
        var main = try #require(library.queues.first { $0.id == DownloadQueue.mainDownloadID })
        main.concurrentDownloads = 1
        library.updateQueue(main)
        let server = try LocalHTTPServer()
        bag.servers.append(server)
        var slow = LocalHTTPServer.Resource(body: Data.pattern(count: 2_000_000))
        slow.bytesPerSecond = 200_000
        server.set("/slow.bin", slow)
        server.set("/next.bin", .init(body: Data.pattern(count: 50_000)))
        let first = library.makeItem(from: IncomingDownload(url: server.url("/slow.bin")), folder: downloads.url.path)
        let second = library.makeItem(from: IncomingDownload(url: server.url("/next.bin")), folder: downloads.url.path)
        library.add(first, start: false)
        library.add(second, start: false)
        library.startQueue(DownloadQueue.mainDownloadID)

        let deadline = Date().addingTimeInterval(15)
        while library.item(first.id)?.status != .downloading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        library.remove([first.id], deleteFiles: true)
        while library.item(second.id)?.status != .completed, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(library.item(second.id)?.status == .completed)
        #expect(!library.isQueueRunning(DownloadQueue.mainDownloadID))
    }
}
