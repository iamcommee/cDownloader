import CommonCrypto
import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct HLSTests {
    let base = URL(string: "https://cdn.example/video/master.m3u8")!

    @Test func t11_01_masterPlaylistVariantsAndSelection() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        https://other.example/hi/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=960x540
        /abs/mid.m3u8
        """
        guard case .master(let variants) = try HLSParser.parse(text, baseURL: base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(variants.map(\.bandwidth) == [800_000, 2_500_000, 1_400_000])
        #expect(variants[0].url.absoluteString == "https://cdn.example/video/low/index.m3u8")
        #expect(variants[0].codecs == "avc1.4d401e,mp4a.40.2")
        #expect(variants[2].url.absoluteString == "https://cdn.example/abs/mid.m3u8")
        #expect(variants[1].resolution == "1280x720")
        #expect(HLSParser.select(variants, index: nil)?.bandwidth == 2_500_000)
        #expect(HLSParser.select(variants, index: 0)?.bandwidth == 800_000)
        #expect(HLSParser.select(variants, index: 9)?.bandwidth == 2_500_000)
    }

    @Test func t11_02_mediaPlaylistSegmentsKeysRangesAndMap() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:40
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXTINF:6.0,
        seg0.m4s
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/k1",IV=0x000102030405060708090A0B0C0D0E0F
        #EXTINF:5.5,
        #EXT-X-BYTERANGE:1000@200
        all.ts
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:500
        all.ts
        #EXT-X-KEY:METHOD=AES-128,URI="k2"
        #EXTINF:3.0,
        seg3.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:2.0,
        seg4.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let playlist) = try HLSParser.parse(text, baseURL: base) else {
            Issue.record("expected a media playlist")
            return
        }
        #expect(playlist.mediaSequence == 40)
        #expect(playlist.isEnded)
        #expect(playlist.segments.map(\.sequence) == [40, 41, 42, 43, 44])
        #expect(playlist.segments.map(\.duration) == [6.0, 5.5, 4.0, 3.0, 2.0])
        #expect(playlist.initSegment?.url.absoluteString == "https://cdn.example/video/init.mp4")
        #expect(playlist.initSegment?.byteRange == 0...719)
        #expect(playlist.segments[1].byteRange == 200...1199)
        #expect(playlist.segments[2].byteRange == 1200...1699)
        #expect(playlist.segments[0].key == nil)
        #expect(playlist.segments[1].key?.uri?.absoluteString == "https://keys.example/k1")
        #expect(playlist.segments[1].effectiveIV == Data((0..<16).map { UInt8($0) }))
        #expect(playlist.segments[3].key?.uri?.absoluteString == "https://cdn.example/video/k2")
        #expect(playlist.segments[3].effectiveIV == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 43]))
        #expect(playlist.segments[4].key == nil)
        #expect(playlist.totalDuration == 20.5)
    }

    @Test func t11_04_masterPlaylistLinksTheSeparateSoundTrack() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="Main",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/main.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub1",NAME="English",URI="subs/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud1",SUBTITLES="sub1"
        video/720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360
        video/360.m3u8
        """
        guard case .master(let variants) = try HLSParser.parse(text, baseURL: base) else {
            Issue.record("expected a master playlist")
            return
        }
        #expect(variants[0].audio?.url.absoluteString == "https://cdn.example/video/audio/main.m3u8")
        #expect(variants[0].audio?.isDefault == true)
        #expect(variants[0].audio?.name == "Main")
        #expect(variants[1].audio == nil)
    }

    @Test func t11_02_defaultSequenceIsZero() throws {
        let text = "#EXTM3U\n#EXTINF:1,\na.ts\n#EXT-X-ENDLIST\n"
        guard case .media(let playlist) = try HLSParser.parse(text, baseURL: base) else {
            Issue.record("media expected")
            return
        }
        #expect(playlist.segments.first?.sequence == 0)
    }

    struct RejectRow: Sendable, CustomTestStringConvertible {
        var label: String
        var text: String
        var error: HLSError
        var testDescription: String { label }
    }

    @Test(arguments: [
        RejectRow(label: "live", text: "#EXTM3U\n#EXTINF:6,\na.ts\n", error: .liveStreamNotSupported),
        RejectRow(label: "sample-aes", text: "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n#EXTINF:6,\na.ts\n#EXT-X-ENDLIST\n", error: .protectedContent),
        RejectRow(label: "fairplay keyformat", text: "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"skd://x\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n#EXTINF:6,\na.ts\n#EXT-X-ENDLIST\n", error: .protectedContent),
        RejectRow(label: "widevine", text: "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"data:x\",KEYFORMAT=\"urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed\"\n#EXTINF:6,\na.ts\n#EXT-X-ENDLIST\n", error: .protectedContent),
        RejectRow(label: "not a playlist", text: "<html>nope</html>", error: .notAPlaylist),
    ])
    func t11_02_rejectsLiveProtectedAndNonPlaylists(row: RejectRow) {
        #expect(throws: row.error) { try HLSParser.parse(row.text, baseURL: base) }
    }

    // MARK: T11-03

    static func encrypt(_ data: Data, key: Data, iv: Data) -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out.prefix(moved)
    }

    struct Fixture {
        let server: LocalHTTPServer
        let plain: [Data]
    }

    /// Four pieces: 0 plain, 1 AES with explicit IV, 2 AES with sequence IV, 3 plain. Early pieces are slow.
    func makeStream(dropFirstSegment: Int = 0) throws -> Fixture {
        let server = try LocalHTTPServer()
        let key = Data((0..<16).map { UInt8(200 - $0) })
        let iv = Data((0..<16).map { UInt8($0 * 3) })
        let plain = (0..<4).map { Data.pattern(count: 150_000 + $0 * 1000, seed: UInt32(10 + $0)) }
        let bodies = [plain[0], Self.encrypt(plain[1], key: key, iv: iv), Self.encrypt(plain[2], key: key, iv: HLSSegment(url: server.url("/"), duration: 0, sequence: 102).effectiveIV), plain[3]]
        for (index, body) in bodies.enumerated() {
            var resource = LocalHTTPServer.Resource(body: body, contentType: "video/mp2t")
            resource.bytesPerSecond = [300_000, 600_000, 2_000_000, 8_000_000][index]
            if index == 0 {
                resource.dropAfterBytes = 1000
                resource.dropCount = dropFirstSegment
            }
            server.set("/v/s\(index).ts", resource)
        }
        server.set("/v/key.bin", .init(body: key))
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:4,
        s0.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x\(iv.map { String(format: "%02x", $0) }.joined())
        #EXTINF:4,
        s1.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4,
        s2.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4,
        s3.ts
        #EXT-X-ENDLIST
        """
        server.set("/v/index.m3u8", .init(body: Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl"))
        return Fixture(server: server, plain: plain)
    }

    func run(_ fixture: Fixture, dir: TempDir, retries: Int = 3) async throws -> DownloadItem {
        var configuration = EngineConfiguration(temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        configuration.maxConnections = 4
        configuration.retriesPerConnection = retries
        configuration.retryDelay = 0.05
        let engine = DownloadEngine(configuration: configuration, secrets: InMemorySecretStore())
        var item = DownloadItem(url: fixture.server.url("/v/index.m3u8"), fileName: "", directory: dir.url.appendingPathComponent("out").path)
        item.kind = .hls(variantIndex: nil)
        let recorder = JobRecorder()
        let runner = engine.makeRunner(for: item) { recorder.handle($0) }
        runner.start()
        return try await recorder.waitForFinish()
    }

    @Test func t11_03_downloadsDecryptsAndJoinsInOrder() async throws {
        let dir = TempDir()
        let fixture = try makeStream(dropFirstSegment: 1)
        let result = try await run(fixture, dir: dir)
        #expect(result.status == .completed)
        #expect(result.fileName == "index.ts")
        #expect(try Data(contentsOf: result.destinationURL) == fixture.plain.reduce(Data(), +))
        #expect(fixture.server.requests(for: "/v/key.bin").count == 1)
        #expect(fixture.server.requests(for: "/v/s0.ts").count == 2)
    }

    @Test func t11_05_playlistNameBecomesAVideoName() async throws {
        let dir = TempDir()
        let fixture = try makeStream()
        var configuration = EngineConfiguration(temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        configuration.retryDelay = 0.05
        let engine = DownloadEngine(configuration: configuration, secrets: InMemorySecretStore())
        var item = DownloadItem(url: fixture.server.url("/v/index.m3u8"), fileName: "index.m3u8", directory: dir.url.appendingPathComponent("out").path)
        item.kind = .hls(variantIndex: nil)
        let recorder = JobRecorder()
        engine.makeRunner(for: item) { recorder.handle($0) }.start()
        let result = try await recorder.waitForFinish()
        #expect(result.status == .completed)
        #expect(result.fileName == "index.ts")
        #expect(try Data(contentsOf: result.destinationURL) == fixture.plain.reduce(Data(), +))
    }

    @Test func t11_06_separateSoundTrackIsDownloadedToo() async throws {
        let dir = TempDir()
        let server = try LocalHTTPServer()
        let video = (0..<3).map { Data.pattern(count: 40_000, seed: UInt32(30 + $0)) }
        let audio = (0..<2).map { Data.pattern(count: 9_000, seed: UInt32(40 + $0)) }
        for (index, piece) in video.enumerated() { server.set("/s/v\(index).ts", .init(body: piece)) }
        for (index, piece) in audio.enumerated() { server.set("/s/a\(index).aac", .init(body: piece)) }
        server.set("/s/video.m3u8", .init(body: Data("#EXTM3U\n#EXTINF:2,\nv0.ts\n#EXTINF:2,\nv1.ts\n#EXTINF:2,\nv2.ts\n#EXT-X-ENDLIST\n".utf8)))
        server.set("/s/audio.m3u8", .init(body: Data("#EXTM3U\n#EXTINF:3,\na0.aac\n#EXTINF:3,\na1.aac\n#EXT-X-ENDLIST\n".utf8)))
        server.set("/s/master.m3u8", .init(body: Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO="a"
        video.m3u8
        """.utf8)))
        var configuration = EngineConfiguration(temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        configuration.retryDelay = 0.05
        configuration.ffmpegPath = nil
        let engine = DownloadEngine(configuration: configuration, secrets: InMemorySecretStore())
        var item = DownloadItem(url: server.url("/s/master.m3u8"), fileName: "", directory: dir.url.appendingPathComponent("out").path)
        item.kind = .hls(variantIndex: nil)
        let recorder = JobRecorder()
        engine.makeRunner(for: item) { recorder.handle($0) }.start()
        let result = try await recorder.waitForFinish()
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.destinationURL) == video.reduce(Data(), +))
        let soundFile = result.destinationURL.deletingPathExtension().appendingPathExtension("audio.aac")
        #expect(try Data(contentsOf: soundFile) == audio.reduce(Data(), +))
        #expect(server.requests(for: "/s/audio.m3u8").count == 1)
    }

    static var ffmpeg: String? { FFmpeg.locate() }

    /// Runs a tool and returns its standard output.
    @discardableResult
    static func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(.enabled(if: HLSTests.ffmpeg != nil, "needs ffmpeg"))
    func t11_07_withFFmpegTheSoundIsJoinedIntoOneMP4() async throws {
        let ffmpeg = try #require(Self.ffmpeg)
        let dir = TempDir()
        let media = dir.url.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Self.runTool(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=3:size=160x120:rate=10", "-c:v", "libx264", "-an",
                                  "-f", "hls", "-hls_time", "1", "-hls_list_size", "0", "-hls_segment_filename", media.appendingPathComponent("v%d.ts").path, media.appendingPathComponent("video.m3u8").path])
        try Self.runTool(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:a", "aac", "-vn",
                                  "-f", "hls", "-hls_time", "1", "-hls_list_size", "0", "-hls_segment_filename", media.appendingPathComponent("a%d.ts").path, media.appendingPathComponent("audio.m3u8").path])
        let server = try LocalHTTPServer()
        for name in try FileManager.default.contentsOfDirectory(atPath: media.path) {
            server.set("/m/\(name)", .init(body: try Data(contentsOf: media.appendingPathComponent(name))))
        }
        server.set("/m/master.m3u8", .init(body: Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Main",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=160x120,AUDIO="aud"
        video.m3u8
        """.utf8)))
        var configuration = EngineConfiguration(temporaryDirectory: dir.url.appendingPathComponent("tmp"))
        configuration.ffmpegPath = ffmpeg
        let engine = DownloadEngine(configuration: configuration, secrets: InMemorySecretStore())
        var item = DownloadItem(url: server.url("/m/master.m3u8"), fileName: "clip.m3u8", directory: dir.url.appendingPathComponent("out").path)
        item.kind = .hls(variantIndex: nil)
        let recorder = JobRecorder()
        engine.makeRunner(for: item) { recorder.handle($0) }.start()
        let result = try await recorder.waitForFinish(timeout: 60)
        #expect(result.status == .completed)
        #expect(result.fileName == "clip.mp4")
        let probe = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let streams = try Self.runTool(probe, ["-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", result.destinationURL.path])
        #expect(streams.contains("video"))
        #expect(streams.contains("audio"))
    }

    @Test func t11_03_persistentPieceFailureFailsTheDownload() async throws {
        let dir = TempDir()
        let fixture = try makeStream(dropFirstSegment: 100)
        let result = try await run(fixture, dir: dir, retries: 2)
        #expect(result.status == .failed)
        #expect(!(result.errorMessage ?? "").isEmpty)
        #expect(fixture.server.requests(for: "/v/s0.ts").count == 3)
    }

    @Test func t11_03_protectedStreamFailsBeforeDownloadingPieces() async throws {
        let dir = TempDir()
        let server = try LocalHTTPServer()
        server.set("/v/index.m3u8", .init(body: Data("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://k\"\n#EXTINF:4,\ns0.ts\n#EXT-X-ENDLIST\n".utf8)))
        server.set("/v/s0.ts", .init(body: Data(count: 100)))
        let result = try await run(Fixture(server: server, plain: []), dir: dir)
        #expect(result.status == .failed)
        #expect(result.errorMessage == HLSError.protectedContent.message)
        #expect(server.requests(for: "/v/s0.ts").isEmpty)
    }
}
