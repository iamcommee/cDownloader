import Foundation
import Testing
@testable import cDownloaderCore

@Suite struct ProtocolTests {
    // MARK: T13-01

    struct CLIRow: Sendable, CustomTestStringConvertible {
        var label: String
        var args: [String]
        var expected: CLICommand?
        var testDescription: String { label }
    }

    static let u = URL(string: "https://h.example/f.zip")!

    @Test(arguments: [
        CLIRow(label: "basic", args: ["-d", "https://h.example/f.zip"], expected: .download(url: u, folder: nil, fileName: nil, quitAfter: false, silent: false, addOnly: false)),
        CLIRow(label: "all", args: ["-d", "https://h.example/f.zip", "-p", "/tmp", "-f", "n.zip", "-q", "-n", "-a"], expected: .download(url: u, folder: "/tmp", fileName: "n.zip", quitAfter: true, silent: true, addOnly: true)),
        CLIRow(label: "start", args: ["-s"], expected: .startQueue),
        CLIRow(label: "idm style", args: ["/d", "https://h.example/f.zip", "/p", "/tmp"], expected: .download(url: u, folder: "/tmp", fileName: nil, quitAfter: false, silent: false, addOnly: false)),
        CLIRow(label: "help", args: ["--help"], expected: .help),
        CLIRow(label: "p without d", args: ["-p", "/tmp"], expected: nil),
        CLIRow(label: "q without d", args: ["-q"], expected: nil),
        CLIRow(label: "n without d", args: ["-n"], expected: nil),
        CLIRow(label: "a without d", args: ["-a"], expected: nil),
        CLIRow(label: "f without d", args: ["-f", "x.zip"], expected: nil),
        CLIRow(label: "d and s", args: ["-d", "https://h.example/f.zip", "-s"], expected: nil),
        CLIRow(label: "no args", args: [], expected: nil),
        CLIRow(label: "missing value", args: ["-d"], expected: nil),
        CLIRow(label: "bad URL", args: ["-d", "notaurl"], expected: nil),
        CLIRow(label: "unknown option", args: ["-x"], expected: nil),
    ])
    func t13_01_parsesCommandLine(row: CLIRow) {
        if let expected = row.expected {
            #expect((try? CommandLineParser.parse(row.args)) == expected)
        } else {
            #expect(throws: CLIError.self) { try CommandLineParser.parse(row.args) }
        }
    }

    // MARK: RN (rename to cDownloader)

    @Test func rn01_namesUseCDownloader() {
        #expect(AppPaths.bundleIdentifier == "com.cdownloader.app")
        #expect(AppPaths.nativeHostName == "com.cdownloader.host")
        #expect(AppPaths.supportDirectory.lastPathComponent == "cDownloader" || ProcessInfo.processInfo.environment["CDOWNLOADER_SUPPORT_DIR"] != nil)
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 120), isDirectory: true)
        #expect(AppPaths.socketPath(for: long).hasSuffix("/cdownloader.sock"))
    }

    @Test func rn03_terminalHelpUsesTheNewCommand() {
        #expect(CommandLineParser.usageText.contains("cdownloader -d URL"))
        // The old command name, split so searches for leftover old names do not flag this line.
        #expect(!CommandLineParser.usageText.lowercased().contains("download" + "di"))
    }

    // MARK: T13-02

    func shortSocketPath() -> String {
        "/tmp/cdl-\(UUID().uuidString.prefix(8)).sock"
    }

    func echoServer(_ path: String) throws -> IPCServer {
        let server = IPCServer(socketPath: path) { request in
            IPCReply(ok: true, error: request.type.rawValue + ":" + String(request.downloads?.count ?? 0))
        }
        try server.start()
        return server
    }

    @Test func t13_02_requestAndReplyRoundTrip() throws {
        let path = shortSocketPath()
        let server = try echoServer(path)
        defer { server.stop() }
        let reply = try IPCClient.send(IPCRequest(type: .add, downloads: [IncomingDownload(url: Self.u)]), socketPath: path)
        #expect(reply == IPCReply(ok: true, error: "add:1"))
        let ping = try IPCClient.send(IPCRequest(type: .ping), socketPath: path)
        #expect(ping.error == "ping:0")
    }

    @Test func t13_02_framingAcrossWritesAndBadJSON() throws {
        let path = shortSocketPath()
        let server = try echoServer(path)
        defer { server.stop() }
        let two = Data("{\"type\":\"ping\"}\n{\"type\":\"startQueue\"}\n".utf8)
        #expect(try IPCClient.exchange(raw: two, socketPath: path, replies: 2).map(\.error) == ["ping:0", "startQueue:0"])
        let bad = Data("{not json}\n{\"type\":\"ping\"}\n".utf8)
        let replies = try IPCClient.exchange(raw: bad, socketPath: path, replies: 2)
        #expect(replies.first?.ok == false)
        #expect(replies.last == IPCReply(ok: true, error: "ping:0"))
    }

    @Test func t13_02_missingServerAndLongPath() {
        #expect(throws: IPCError.appNotRunning) { try IPCClient.send(IPCRequest(type: .ping), socketPath: shortSocketPath()) }
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: IPCError.pathTooLong) { try IPCClient.send(IPCRequest(type: .ping), socketPath: long) }
        #expect(throws: IPCError.pathTooLong) { try IPCServer(socketPath: long) { _ in IPCReply(ok: true) }.start() }
    }

    // MARK: T13-03

    @Test func t13_03_frameRoundTripWithExactBytes() throws {
        let json = Data(#"{"a":"é"}"#.utf8)
        let frame = try NativeMessagingCodec.encode(json)
        #expect(frame.prefix(4) == Data([UInt8(json.count), 0, 0, 0]))
        #expect(json.count == 10, "é is two bytes, so the length counts bytes not characters")
        #expect(frame.dropFirst(4) == json)
        var decoder = NativeMessagingCodec.Decoder()
        #expect(try decoder.append(frame) == [json])
    }

    @Test func t13_03_twoFramesAndSplitFrames() throws {
        let a = try NativeMessagingCodec.encode(Data(#"{"n":1}"#.utf8))
        let b = try NativeMessagingCodec.encode(Data(#"{"n":2}"#.utf8))
        var decoder = NativeMessagingCodec.Decoder()
        #expect(try decoder.append(a + b).count == 2)

        var split = NativeMessagingCodec.Decoder()
        let whole = a + b
        #expect(try split.append(whole.prefix(2)).isEmpty)
        #expect(try split.append(whole.dropFirst(2).prefix(5)).isEmpty)
        let rest = try split.append(whole.dropFirst(7))
        #expect(rest == [Data(#"{"n":1}"#.utf8), Data(#"{"n":2}"#.utf8)])
        try split.finish()
    }

    struct BadFrameRow: Sendable, CustomTestStringConvertible {
        var label: String
        var bytes: [UInt8]
        var error: NativeMessagingError
        var testDescription: String { label }
    }

    @Test(arguments: [
        BadFrameRow(label: "zero length", bytes: [0, 0, 0, 0], error: .emptyMessage),
        BadFrameRow(label: "too large", bytes: [0, 0, 0, 0x7F], error: .tooLarge(0x7F00_0000)),
        BadFrameRow(label: "invalid json", bytes: [3, 0, 0, 0] + Array("{x}".utf8), error: .invalidJSON),
        BadFrameRow(label: "invalid utf8", bytes: [2, 0, 0, 0, 0xFF, 0xFE], error: .invalidJSON),
    ])
    func t13_03_rejectsBadFrames(row: BadFrameRow) {
        var decoder = NativeMessagingCodec.Decoder()
        #expect(throws: row.error) { try decoder.append(Data(row.bytes)) }
    }

    @Test func t13_03_endOfInputMidFrameIsAnError() throws {
        var decoder = NativeMessagingCodec.Decoder()
        let frame = try NativeMessagingCodec.encode(Data(#"{"n":1}"#.utf8))
        _ = try decoder.append(frame.prefix(6))
        #expect(throws: NativeMessagingError.truncated) { try decoder.finish() }
        #expect(throws: NativeMessagingError.tooLarge(NativeMessagingCodec.maxOutgoingLength + 1)) {
            try NativeMessagingCodec.encode(Data(count: NativeMessagingCodec.maxOutgoingLength + 1))
        }
    }
}

@Suite struct NativeHostInstallerTests {
    @Test func t14_04_writesManifestOnlyForInstalledBrowsers() throws {
        let dir = TempDir()
        let support = dir.url
        for folder in ["Google/Chrome", "BraveSoftware/Brave-Browser"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let host = URL(fileURLWithPath: "/Applications/cDownloader.app/Contents/MacOS/cDownloaderHost")
        let written = try NativeHostInstaller.install(hostExecutable: host, extensionIDs: ["abcdefghijklmnopabcdefghijklmnop"], applicationSupport: support)
        #expect(written.count == 2)
        let chrome = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/com.cdownloader.host.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: chrome)) as? [String: Any]
        #expect(json?["name"] as? String == "com.cdownloader.host")
        #expect(json?["type"] as? String == "stdio")
        #expect(json?["path"] as? String == host.path)
        #expect(json?["allowed_origins"] as? [String] == ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Microsoft Edge").path))
        #expect(NativeHostInstaller.installedBrowsers(applicationSupport: support) == ["Google/Chrome", "BraveSoftware/Brave-Browser"])

        NativeHostInstaller.uninstall(applicationSupport: support)
        #expect(!FileManager.default.fileExists(atPath: chrome.path))
        #expect(NativeHostInstaller.installedBrowsers(applicationSupport: support).isEmpty)
    }

    // MARK: TC-01 the helper stays registered at every launch, whatever "Take over downloads" is set to

    struct RegisterRow: Sendable, CustomTestStringConvertible {
        var label: String
        /// Where a registration left by an earlier launch points, if there is one.
        var earlierPath: String?
        var hasHost: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        RegisterRow(label: "earlier registration from another app location", earlierPath: "/Users/x/Downloads/cDownloader.app/Contents/MacOS/cDownloaderHost", hasHost: true),
        RegisterRow(label: "no registration yet", earlierPath: nil, hasHost: true),
        RegisterRow(label: "no helper program", earlierPath: "/Users/x/Downloads/cDownloader.app/Contents/MacOS/cDownloaderHost", hasHost: false),
    ])
    func tc01_registerKeepsHelperReachable(row: RegisterRow) throws {
        let dir = TempDir()
        let support = dir.url
        let browsers = ["Google/Chrome", "BraveSoftware/Brave-Browser"]
        let id = "abcdefghijklmnopabcdefghijklmnop"
        for folder in browsers {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        if let earlier = row.earlierPath {
            try NativeHostInstaller.install(hostExecutable: URL(fileURLWithPath: earlier), extensionIDs: [id], applicationSupport: support)
        }
        let host = row.hasHost ? URL(fileURLWithPath: "/Applications/cDownloader.app/Contents/MacOS/cDownloaderHost") : nil

        for launch in 1...2 {
            let written = NativeHostInstaller.register(hostExecutable: host, extensionIDs: [id], applicationSupport: support)
            #expect(written.count == (host == nil ? 0 : browsers.count), "launch \(launch)")
            for folder in browsers {
                let file = support.appendingPathComponent("\(folder)/NativeMessagingHosts/com.cdownloader.host.json")
                let json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                #expect(json?["path"] as? String == host?.path ?? row.earlierPath, "\(folder), launch \(launch)")
                #expect(json?["allowed_origins"] as? [String] == ["chrome-extension://\(id)/"], "\(folder), launch \(launch)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Microsoft Edge").path))
    }
}
