import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct FTPTests {
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

    func item(_ url: URL, fileName: String = "f.bin") -> DownloadItem {
        DownloadItem(url: url, fileName: fileName, directory: dir.url.appendingPathComponent("out").path)
    }

    func run(_ engine: DownloadEngine, _ item: DownloadItem) async throws -> DownloadItem {
        let recorder = JobRecorder()
        let job = engine.makeJob(for: item) { recorder.handle($0) }
        job.start()
        return try await recorder.waitForFinish()
    }

    func restOffsets(_ commands: [String]) -> [Int64] {
        commands.filter { $0.hasPrefix("REST ") }.compactMap { Int64($0.dropFirst(5)) }
    }

    @Test func t7_01_downloadsWithLoginAndPassiveMode() async throws {
        let server = try LocalFTPServer()
        server.account = .init(user: "bob", password: "pw")
        let body = Data.pattern(count: 400_000)
        server.setFile("/pub/f.bin", body)
        let result = try await run(makeEngine(), item(server.url("/pub/f.bin", user: "bob", password: "pw")))
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        let commands = server.commands
        #expect(commands.contains("USER bob"))
        #expect(commands.contains("PASS pw"))
        #expect(commands.contains("TYPE I"))
        #expect(commands.contains("SIZE /pub/f.bin"))
        #expect(commands.contains("RETR /pub/f.bin"))
        #expect(result.totalBytes == 400_000)
    }

    @Test func t7_01_fallsBackToPASVWhenEPSVIsRejected() async throws {
        let server = try LocalFTPServer()
        server.supportsEPSV = false
        let body = Data.pattern(count: 50_000)
        server.setFile("/f.bin", body)
        let result = try await run(makeEngine(), item(server.url("/f.bin")))
        #expect(result.status == .completed)
        #expect(server.commands.contains("PASV"))
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }

    @Test func t7_01_wrongPasswordFailsWithAuthReason() async throws {
        let server = try LocalFTPServer()
        server.account = .init(user: "bob", password: "pw")
        server.setFile("/f.bin", Data.pattern(count: 1000))
        let result = try await run(makeEngine(), item(server.url("/f.bin", user: "bob", password: "nope")))
        #expect(result.status == .failed)
        #expect(result.errorMessage == DownloadFailure.authenticationRequired.message)
    }

    @Test func t7_01_missingFileFails() async throws {
        let server = try LocalFTPServer()
        let result = try await run(makeEngine(), item(server.url("/nothing.bin")))
        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("550") == true)
    }

    @Test func t7_02_segmentsUseRestAndResumeFromSavedPositions() async throws {
        let server = try LocalFTPServer()
        let body = Data.pattern(count: 1_200_000)
        server.setFile("/f.bin", body)
        server.bytesPerSecond = 500_000
        let engine = makeEngine { $0.maxConnections = 3 }

        let recorder = JobRecorder()
        let job = engine.makeJob(for: item(server.url("/f.bin"))) { recorder.handle($0) }
        job.start()
        try await recorder.waitUntil { recorder.downloaded >= 300_000 }
        job.pause()
        let paused = try await recorder.waitForFinish()
        #expect(paused.status == .stopped)
        #expect(paused.resumable)
        #expect(server.peakConcurrentTransfers >= 2)
        #expect(restOffsets(server.commands).contains { $0 > 0 })

        let before = server.commands.count
        server.bytesPerSecond = nil
        let result = try await run(engine, paused)
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        let saved = Set(paused.segments.filter { !$0.isFinished }.map(\.position))
        #expect(saved.isSubset(of: Set(restOffsets(Array(server.commands[before...])))))
    }

    @Test func t7_02_serverWithoutRestUsesOneConnectionAndRestarts() async throws {
        let server = try LocalFTPServer()
        server.supportsRest = false
        let body = Data.pattern(count: 600_000)
        server.setFile("/f.bin", body)
        server.bytesPerSecond = 600_000
        let engine = makeEngine { $0.maxConnections = 4 }

        let recorder = JobRecorder()
        let job = engine.makeJob(for: item(server.url("/f.bin"))) { recorder.handle($0) }
        job.start()
        try await recorder.waitUntil { recorder.downloaded >= 100_000 }
        job.pause()
        let paused = try await recorder.waitForFinish()
        #expect(!paused.resumable)
        #expect(server.peakConcurrentTransfers == 1)

        let before = server.commands.count
        server.bytesPerSecond = nil
        let result = try await run(engine, paused)
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == body)
        #expect(restOffsets(Array(server.commands[before...])).allSatisfy { $0 == 0 })
    }

    @Test func t7_02_anonymousLoginAndDecodedFileName() async throws {
        let server = try LocalFTPServer()
        let body = Data.pattern(count: 10_000)
        server.setFile("/pub/my file.bin", body)
        let result = try await run(makeEngine(), item(server.url("/pub/my file.bin"), fileName: ""))
        #expect(result.status == .completed)
        #expect(result.fileName == "my file.bin")
        #expect(server.commands.contains("USER anonymous"))
        #expect(try Data(contentsOf: result.destinationURL) == body)
    }
}
