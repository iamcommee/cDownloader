import Foundation
import Testing
@testable import cDownloaderCore

/// Collects job events so tests can wait for an outcome.
final class JobRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _finished: DownloadItem?
    private var _lastCheckpoint: DownloadItem?
    private var _downloaded: Int64 = 0
    private var _sawRestart = false

    func handle(_ event: DownloadJob.Event) {
        lock.withLock {
            switch event {
            case .completed(let item), .failed(let item), .paused(let item):
                _finished = item
            case .checkpoint(let item):
                _lastCheckpoint = item
                _downloaded = max(_downloaded, item.downloadedBytes)
            case .progress(let snapshot):
                _downloaded = snapshot.downloadedBytes
            case .started:
                break
            }
        }
    }

    var finished: DownloadItem? { lock.withLock { _finished } }
    var lastCheckpoint: DownloadItem? { lock.withLock { _lastCheckpoint } }
    var downloaded: Int64 { lock.withLock { _downloaded } }

    func reset() { lock.withLock { _finished = nil } }

    @discardableResult
    func waitForFinish(timeout: TimeInterval = 30) async throws -> DownloadItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let finished { return finished }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TimeoutError()
    }

    func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimeoutError()
    }

    struct TimeoutError: Error {}
}

@Suite struct HTTPEngineTests {
    let dir = TempDir()

    func makeEngine(limiter: SpeedLimiter = SpeedLimiter(), _ configure: (inout EngineConfiguration) -> Void = { _ in }) -> DownloadEngine {
        var configuration = EngineConfiguration(temporaryDirectory: dir.url.appendingPathComponent("tmp", isDirectory: true))
        configuration.minSegmentSize = 32 * 1024
        configuration.retryDelay = 0.05
        configuration.checkpointInterval = 0.05
        configuration.timeout = 10
        configure(&configuration)
        return DownloadEngine(configuration: configuration, secrets: InMemorySecretStore(), limiter: limiter)
    }

    func makeItem(_ server: LocalHTTPServer, _ path: String = "/f.bin", fileName: String = "f.bin") -> DownloadItem {
        DownloadItem(url: server.url(path), fileName: fileName, directory: dir.url.appendingPathComponent("out").path)
    }

    func run(_ engine: DownloadEngine, _ item: DownloadItem, timeout: TimeInterval = 30) async throws -> (DownloadItem, JobRecorder, DownloadJob) {
        let recorder = JobRecorder()
        let job = engine.makeJob(for: item) { recorder.handle($0) }
        job.start()
        let result = try await recorder.waitForFinish(timeout: timeout)
        return (result, recorder, job)
    }

    /// Starts a job, waits for `bytes` to arrive, pauses it and returns the paused item.
    func startAndPause(_ engine: DownloadEngine, _ item: DownloadItem, after bytes: Int64) async throws -> (DownloadItem, DownloadJob) {
        let recorder = JobRecorder()
        let job = engine.makeJob(for: item) { recorder.handle($0) }
        job.start()
        try await recorder.waitUntil { recorder.downloaded >= bytes }
        job.pause()
        let paused = try await recorder.waitForFinish()
        return (paused, job)
    }

    func rangeStart(_ request: LocalHTTPServer.RecordedRequest) -> Int64? {
        guard let range = request.headers["range"], range.hasPrefix("bytes="), range.hasSuffix("-") else { return nil }
        return Int64(range.dropFirst(6).dropLast())
    }

    // MARK: T6-01

    @Test func t6_01_segmentedDownloadUsesOpenEndedRangesAndConnectionLimit() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 2_000_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.bytesPerSecond = 1_500_000
        resource.etag = "\"e1\""
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 4 }

        let (result, _, job) = try await run(engine, makeItem(server))
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        let requests = server.requests(for: "/f.bin")
        #expect(requests.count > 1)
        #expect(requests.allSatisfy { rangeStart($0) != nil }, "every request must use an open-ended range")
        // Counted where the limit applies: the server may still be sending to a connection the client
        // has already closed, so its own count can briefly read one higher under load.
        #expect(job.peakConnections <= 4)
        #expect(server.peakConcurrentBodies >= 2, "pieces must really download in parallel")
        #expect(result.resumable)
        #expect(result.totalBytes == 2_000_000)
    }

    @Test func t6_01_singleConnectionSettingMakesOneRequest() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 500_000)
        server.set("/f.bin", .init(body: body))
        let engine = makeEngine { $0.maxConnections = 1 }
        let (result, _, _) = try await run(engine, makeItem(server))
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        #expect(server.requests(for: "/f.bin").count == 1)
    }

    // MARK: T6-02

    @Test func t6_02_serverWithoutRangesUsesOneConnection() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 700_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.supportsRanges = false
        server.set("/f.bin", resource)
        let (result, _, _) = try await run(makeEngine(), makeItem(server))
        #expect(result.status == .completed)
        #expect(!result.resumable)
        #expect(server.requests(for: "/f.bin").count == 1)
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    @Test func t6_02_unknownLengthDownloadsSequentially() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 300_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.supportsRanges = false
        resource.sendContentLength = false
        server.set("/f.bin", resource)
        let (result, _, _) = try await run(makeEngine(), makeItem(server))
        #expect(result.status == .completed)
        #expect(server.requests(for: "/f.bin").count == 1)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        #expect(result.totalBytes == 300_000)
    }

    @Test func t6_02_resumingNonResumableDownloadRestartsWithoutRange() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 1_000_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.supportsRanges = false
        resource.bytesPerSecond = 1_000_000
        server.set("/f.bin", resource)
        let engine = makeEngine()
        let (paused, _) = try await startAndPause(engine, makeItem(server), after: 100_000)
        #expect(paused.status == .stopped)
        #expect(!paused.resumable)
        server.update("/f.bin") { $0.bytesPerSecond = nil }

        let (result, _, _) = try await run(engine, paused)
        #expect(result.status == .completed)
        let requests = server.requests(for: "/f.bin")
        #expect(requests.count == 2)
        #expect(requests.last?.headers["range"] == nil)
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    // MARK: T6-03

    @Test func t6_03_pauseThenResumeContinuesFromSavedPositions() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 2_000_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.bytesPerSecond = 800_000
        resource.etag = "\"v1\""
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 3 }

        let (paused, job) = try await startAndPause(engine, makeItem(server), after: 400_000)
        #expect(paused.status == .stopped)
        #expect(paused.downloadedBytes > 0)
        #expect(!paused.segments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: job.temporaryFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: paused.destinationURL.path))

        let before = server.requests(for: "/f.bin").count
        server.update("/f.bin") { $0.bytesPerSecond = 4_000_000 }
        let (result, _, _) = try await run(engine, paused)
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)

        let resumed = Array(server.requests(for: "/f.bin")[before...])
        let saved = Set(paused.segments.filter { !$0.isFinished }.map(\.position))
        let starts = Set(resumed.compactMap(rangeStart))
        #expect(saved.isSubset(of: starts), "resume must restart at saved positions \(saved) not \(starts)")
        #expect(resumed.allSatisfy { $0.headers["if-range"] == "\"v1\"" })
    }

    @Test func t6_03_crashRecoveryUsesLastCheckpoint() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 1_500_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.bytesPerSecond = 600_000
        resource.etag = "\"c1\""
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 2 }

        let recorder = JobRecorder()
        let job = engine.makeJob(for: makeItem(server)) { recorder.handle($0) }
        job.start()
        try await recorder.waitUntil { (recorder.lastCheckpoint?.downloadedBytes ?? 0) >= 300_000 }
        job.abandonForTesting()
        let checkpoint = try #require(recorder.lastCheckpoint)

        let before = server.requests(for: "/f.bin").count
        server.update("/f.bin") { $0.bytesPerSecond = nil }
        let (result, _, _) = try await run(engine, checkpoint)
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        let starts = Set(server.requests(for: "/f.bin")[before...].compactMap(rangeStart))
        let saved = Set(checkpoint.segments.filter { !$0.isFinished }.map(\.position))
        #expect(saved.isSubset(of: starts))
    }

    // MARK: T6-04

    @Test func t6_04_changedFileOnServerRestartsFromZero() async throws {
        let server = try LocalHTTPServer()
        let v1 = Data.pattern(count: 1_200_000, seed: 1)
        let v2 = Data.pattern(count: 1_100_000, seed: 2)
        var resource = LocalHTTPServer.Resource(body: v1)
        resource.bytesPerSecond = 600_000
        resource.etag = "\"v1\""
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 2 }
        let (paused, _) = try await startAndPause(engine, makeItem(server), after: 200_000)

        server.update("/f.bin") {
            $0.body = v2
            $0.etag = "\"v2\""
            $0.bytesPerSecond = nil
        }
        let (result, _, _) = try await run(engine, paused)
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == v2)
        #expect(result.etag == "\"v2\"")
    }

    @Test func t6_04_ignoringModificationChangesContinuesWithoutValidator() async throws {
        let server = try LocalHTTPServer()
        let v1 = Data.pattern(count: 1_200_000, seed: 1)
        var resource = LocalHTTPServer.Resource(body: v1)
        resource.bytesPerSecond = 600_000
        resource.etag = "\"v1\""
        server.set("/f.bin", resource)
        let engine = makeEngine {
            $0.maxConnections = 2
            $0.ignoreModificationTimeChanges = true
        }
        let (paused, _) = try await startAndPause(engine, makeItem(server), after: 200_000)
        server.update("/f.bin") {
            $0.body = Data.pattern(count: 1_200_000, seed: 2)
            $0.etag = "\"v2\""
            $0.bytesPerSecond = nil
        }
        let before = server.requests(for: "/f.bin").count
        let (result, _, _) = try await run(engine, paused)
        #expect(result.status == .completed)
        let resumed = Array(server.requests(for: "/f.bin")[before...])
        #expect(resumed.allSatisfy { $0.headers["if-range"] == nil })
        let saved = Set(paused.segments.filter { !$0.isFinished }.map(\.position))
        #expect(saved.isSubset(of: Set(resumed.compactMap(rangeStart))))
        #expect(try Data(contentsOf: result.destinationURL).count == 1_200_000)
    }

    @Test func t6_04_lastModifiedIsUsedWhenThereIsNoETag() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 1_000_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.bytesPerSecond = 600_000
        resource.lastModified = "Wed, 01 Jan 2025 00:00:00 GMT"
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 2 }
        let (paused, _) = try await startAndPause(engine, makeItem(server), after: 150_000)
        server.update("/f.bin") { $0.bytesPerSecond = nil }
        let before = server.requests(for: "/f.bin").count
        let (result, _, _) = try await run(engine, paused)
        #expect(result.status == .completed)
        #expect(server.requests(for: "/f.bin")[before...].allSatisfy { $0.headers["if-range"] == "Wed, 01 Jan 2025 00:00:00 GMT" })
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    // MARK: T6-05

    @Test func t6_05_droppedConnectionsAreRetried() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 1_000_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.dropAfterBytes = 300_000
        resource.dropCount = 2
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 1 }
        let (result, _, _) = try await run(engine, makeItem(server))
        #expect(result.status == .completed)
        #expect(server.requests(for: "/f.bin").count == 3)
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    @Test func t6_05_persistentFailureStopsAfterRetryLimit() async throws {
        let server = try LocalHTTPServer()
        var resource = LocalHTTPServer.Resource(body: Data.pattern(count: 100_000))
        resource.dropAfterBytes = 0
        resource.dropCount = 1000
        server.set("/f.bin", resource)
        let engine = makeEngine {
            $0.maxConnections = 1
            $0.retriesPerConnection = 2
        }
        let (result, _, _) = try await run(engine, makeItem(server))
        #expect(result.status == .failed)
        #expect(!(result.errorMessage ?? "").isEmpty)
        #expect(server.requests(for: "/f.bin").count == 3)
    }

    @Test func t6_05_missingFileFailsWithoutRetry() async throws {
        let server = try LocalHTTPServer()
        let (result, _, _) = try await run(makeEngine(), makeItem(server, "/missing.bin"))
        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("404") == true)
        #expect(server.requests(for: "/missing.bin").count == 1)
        #expect(!FileManager.default.fileExists(atPath: result.destinationURL.path))
    }

    // MARK: T6-06

    @Test func t6_06_redirectsAreFollowedAndFinalURLKept() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 200_000)
        server.set("/f.bin", .init(body: body))
        var a = LocalHTTPServer.Resource(body: Data())
        a.redirectTo = "/b"
        var b = LocalHTTPServer.Resource(body: Data())
        b.redirectTo = "/f.bin"
        server.set("/a", a)
        server.set("/b", b)
        let (result, _, _) = try await run(makeEngine(), makeItem(server, "/a"))
        #expect(result.status == .completed)
        #expect(result.finalURL?.path == "/f.bin")
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    @Test func t6_06_redirectLoopFails() async throws {
        let server = try LocalHTTPServer()
        var x = LocalHTTPServer.Resource(body: Data())
        x.redirectTo = "/y"
        var y = LocalHTTPServer.Resource(body: Data())
        y.redirectTo = "/x"
        server.set("/x", x)
        server.set("/y", y)
        let (result, _, _) = try await run(makeEngine(), makeItem(server, "/x"))
        #expect(result.status == .failed)
        #expect(result.errorMessage == DownloadFailure.tooManyRedirects.message)
    }

    @Test func t6_06_userAgentRefererAndCookiesAreSent() async throws {
        let server = try LocalHTTPServer()
        server.set("/f.bin", .init(body: Data.pattern(count: 1000)))
        var item = makeItem(server)
        item.userAgent = "UA-Test/1.0"
        item.referer = "https://ref.example/page"
        item.cookies = "sid=abc; theme=dark"
        let (result, _, _) = try await run(makeEngine(), item)
        #expect(result.status == .completed)
        let request = try #require(server.requests(for: "/f.bin").first)
        #expect(request.headers["user-agent"] == "UA-Test/1.0")
        #expect(request.headers["referer"] == "https://ref.example/page")
        #expect(request.headers["cookie"] == "sid=abc; theme=dark")
    }

    // MARK: T6-07

    func protectedServer() throws -> LocalHTTPServer {
        let server = try LocalHTTPServer()
        var resource = LocalHTTPServer.Resource(body: Data.pattern(count: 50_000))
        resource.basicAuth = .init(user: "u", password: "p")
        server.set("/f.bin", resource)
        return server
    }

    @Test func t6_07_missingCredentialsFailWithAuthReason() async throws {
        let server = try protectedServer()
        let (result, _, _) = try await run(makeEngine(), makeItem(server))
        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("401") == true)
    }

    @Test func t6_07_perDownloadCredentialsWork() async throws {
        let server = try protectedServer()
        let engine = makeEngine()
        var item = makeItem(server)
        item.username = "u"
        engine.secrets.setPassword("p", for: item.credentialKey)
        let (result, _, _) = try await run(engine, item)
        #expect(result.status == .completed)
    }

    @Test func t6_07_siteLoginCredentialsWork() async throws {
        let server = try protectedServer()
        let login = SiteLogin(urlPrefix: server.baseURL.absoluteString + "/", username: "u")
        let engine = makeEngine { $0.siteLogins = [login] }
        engine.secrets.setPassword("p", for: login.credentialKey)
        let (result, _, _) = try await run(engine, makeItem(server))
        #expect(result.status == .completed)
    }

    @Test func t6_07_wrongCredentialsFailWithoutLooping() async throws {
        let server = try protectedServer()
        let engine = makeEngine()
        var item = makeItem(server)
        item.username = "u"
        engine.secrets.setPassword("wrong", for: item.credentialKey)
        let (result, _, _) = try await run(engine, item)
        #expect(result.status == .failed)
        #expect(server.requests(for: "/f.bin").count <= 3)
    }

    // MARK: T6-08

    @Test func t6_08_partialFileIsMovedToServerNameOnCompletion() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 600_000)
        var resource = LocalHTTPServer.Resource(body: body)
        resource.contentDisposition = "attachment; filename=\"report.pdf\""
        resource.bytesPerSecond = 1_000_000
        server.set("/f.bin", resource)
        let engine = makeEngine { $0.maxConnections = 1 }
        let recorder = JobRecorder()
        let job = engine.makeJob(for: makeItem(server, fileName: "")) { recorder.handle($0) }
        job.start()
        do { try await recorder.waitUntil { recorder.downloaded >= 100_000 } } catch {
            Issue.record("Stalled before 100 KB arrived: status=\(job.item.status) bytes=\(job.item.downloadedBytes) recorded=\(recorder.downloaded) finished=\(String(describing: recorder.finished?.status)) err=\(String(describing: recorder.finished?.errorMessage)) requests=\(server.requests.map { $0.headers["range"] ?? "none" })")
            throw error
        }
        let finalURL = dir.url.appendingPathComponent("out/report.pdf")
        #expect(FileManager.default.fileExists(atPath: job.temporaryFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))

        let result: DownloadItem
        do { result = try await recorder.waitForFinish() } catch {
            Issue.record("Never finished: status=\(job.item.status) bytes=\(job.item.downloadedBytes) recorded=\(recorder.downloaded) requests=\(server.requests.map { $0.headers["range"] ?? "none" })")
            throw error
        }
        #expect(result.status == .completed)
        #expect(result.fileName == "report.pdf")
        #expect(try Data(contentsOf: finalURL) == body)
        #expect(!FileManager.default.fileExists(atPath: job.temporaryFileURL.path))
    }

    @Test func t6_08_existingFileGetsNumberedName() async throws {
        let server = try LocalHTTPServer()
        let body = Data.pattern(count: 10_000)
        server.set("/f.bin", .init(body: body))
        let out = dir.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: out.appendingPathComponent("f.bin"))
        let (result, _, _) = try await run(makeEngine(), makeItem(server))
        #expect(result.fileName == "f (1).bin")
        #expect(try Data(contentsOf: out.appendingPathComponent("f (1).bin")) == body)
        #expect(try Data(contentsOf: out.appendingPathComponent("f.bin")) == Data("old".utf8))
    }

    // MARK: T6-09

    @Test func t6_09_speedLimitSlowsTheDownload() async throws {
        let server = try LocalHTTPServer()
        // 2 MB so the limiter's one-second burst allowance cannot make the run finish under a second.
        let body = Data.pattern(count: 2_000_000)
        server.set("/f.bin", .init(body: body))
        let limiter = SpeedLimiter()
        limiter.globalLimit = 500_000
        let engine = makeEngine(limiter: limiter) { $0.maxConnections = 4 }
        let started = Date()
        let (result, _, _) = try await run(engine, makeItem(server))
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.status == .completed)
        #expect(elapsed >= 1.0)
        #expect(elapsed < 10)
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    @Test func t6_09_perServerExceptionLimitsConnections() async throws {
        let server = try LocalHTTPServer()
        var resource = LocalHTTPServer.Resource(body: Data.pattern(count: 1_000_000))
        resource.bytesPerSecond = 2_000_000
        server.set("/f.bin", resource)
        let engine = makeEngine {
            $0.maxConnections = 8
            $0.connectionExceptions = [ConnectionException(hostPattern: "127.0.0.*", maxConnections: 1)]
        }
        let (result, _, _) = try await run(engine, makeItem(server))
        #expect(result.status == .completed)
        #expect(server.peakConcurrentBodies == 1)
        #expect(server.requests(for: "/f.bin").count == 1)
    }
}
