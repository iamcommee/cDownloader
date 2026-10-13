import Foundation
import Testing
@testable import cDownloaderCore

/// The yt-dlp packed inside the app: copying it into the app's own folder at launch, and the daily self-update.
@Suite struct YtDlpUpdaterTests {
    static let packedVersion = "2026.08.19"
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: T18-05

    struct VersionRow: Sendable, CustomTestStringConvertible {
        var label: String
        var a: String
        var b: String
        var expected: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        VersionRow(label: "later day", a: "2026.08.20", b: "2026.08.19", expected: true),
        VersionRow(label: "earlier day", a: "2026.08.19", b: "2026.08.20", expected: false),
        VersionRow(label: "equal", a: "2026.08.19", b: "2026.08.19", expected: false),
        VersionRow(label: "extra part is newer", a: "2026.08.19.1", b: "2026.08.19", expected: true),
        VersionRow(label: "missing part counts as 0", a: "2026.08.19", b: "2026.08.19.1", expected: false),
        VersionRow(label: "missing part equals a 0 part", a: "2026.08.19", b: "2026.08.19.0", expected: false),
        VersionRow(label: "parts compare as numbers", a: "2026.08.19.10", b: "2026.08.19.9", expected: true),
        VersionRow(label: "long time suffix", a: "2026.08.19.232843", b: "2026.08.19.1", expected: true),
        VersionRow(label: "month beats day", a: "2026.10.01", b: "2026.9.30", expected: true),
        VersionRow(label: "a word counts as 0", a: "2026.08.19.x", b: "2026.08.19", expected: false),
        VersionRow(label: "a word against nothing", a: "2026.08.19", b: "2026.08.19.x", expected: false),
        VersionRow(label: "new year", a: "2027.01.01", b: "2026.12.31", expected: true),
        VersionRow(label: "empty is never newer", a: "", b: "2026.08.19", expected: false),
    ])
    func t18_05_versionComparison(row: VersionRow) {
        #expect(YtDlpUpdater.isNewer(row.a, than: row.b) == row.expected)
    }

    // MARK: T18-06

    struct PrepareRow: Sendable, CustomTestStringConvertible {
        var label: String
        /// The own copy's version; nil when there is no own copy.
        var own: String?
        var ownVersionFile = true
        var ownQuarantined = false
        /// The packed copy's version; nil when the app holds no yt-dlp.
        var packed: String?
        var bundledFolder = true
        var packedQuarantined = false
        var twice = false
        /// Which copy the own folder holds afterwards: "packed", "own", or nil for none.
        var expected: String?
        var expectedVersion: String?
        var testDescription: String { label }
    }

    @Test(arguments: [
        PrepareRow(label: "first launch copies the packed one", packed: packedVersion, expected: "packed", expectedVersion: packedVersion),
        PrepareRow(label: "older own copy is replaced", own: "2026.08.01", packed: packedVersion, expected: "packed", expectedVersion: packedVersion),
        PrepareRow(label: "same version is kept", own: packedVersion, packed: packedVersion, expected: "own", expectedVersion: packedVersion),
        PrepareRow(label: "self-updated newer copy is kept", own: "2026.09.02", packed: packedVersion, expected: "own", expectedVersion: "2026.09.02"),
        PrepareRow(label: "own copy without a version is replaced", own: "2026.09.02", ownVersionFile: false, packed: packedVersion,
                   expected: "packed", expectedVersion: packedVersion),
        PrepareRow(label: "nothing packed, nothing made", bundledFolder: false, expected: nil),
        PrepareRow(label: "packed folder without yt-dlp", expected: nil),
        PrepareRow(label: "nothing packed keeps the own copy", own: "2026.08.01", bundledFolder: false, expected: "own", expectedVersion: "2026.08.01"),
        PrepareRow(label: "download mark cleared on a fresh copy", packed: packedVersion, packedQuarantined: true, expected: "packed", expectedVersion: packedVersion),
        PrepareRow(label: "download mark cleared on a kept copy", own: packedVersion, ownQuarantined: true, packed: packedVersion,
                   expected: "own", expectedVersion: packedVersion),
        PrepareRow(label: "running twice changes nothing (guard)", packed: packedVersion, twice: true, expected: "packed", expectedVersion: packedVersion),
    ])
    func t18_06_prepareSeedsTheOwnCopy(row: PrepareRow) throws {
        let temp = TempDir()
        let tools = temp.url.appendingPathComponent("Tools", isDirectory: true)
        let bundled = temp.url.appendingPathComponent("Helpers", isDirectory: true)
        // As in the app: the programs folder may hold only programs, so the version lives with the resources.
        let packedVersionFile = temp.url.appendingPathComponent("Resources/yt-dlp.version")
        let packedText = "#!/bin/sh\n# packed\n", ownText = "#!/bin/sh\n# own\n"
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packedVersionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let packed = row.packed {
            try Self.writeTool(packedText, to: bundled.appendingPathComponent("yt-dlp"), quarantined: row.packedQuarantined)
            try Data(packed.utf8).write(to: packedVersionFile)
        }
        if let own = row.own {
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            try Self.writeTool(ownText, to: tools.appendingPathComponent("yt-dlp"), quarantined: row.ownQuarantined)
            if row.ownVersionFile { try Data(own.utf8).write(to: tools.appendingPathComponent("yt-dlp.version")) }
        }
        let updater = YtDlpUpdater(
            toolsDirectory: tools, bundledDirectory: row.bundledFolder ? bundled : nil, bundledVersionFile: packedVersionFile, environment: [:]
        )

        updater.prepare()
        if row.twice { updater.prepare() }

        let own = tools.appendingPathComponent("yt-dlp")
        switch row.expected {
        case nil:
            #expect(!FileManager.default.fileExists(atPath: own.path))
        case let expected?:
            #expect(try String(contentsOf: own, encoding: .utf8) == (expected == "packed" ? packedText : ownText))
            #expect(FileManager.default.isExecutableFile(atPath: own.path))
            #expect(!Self.isQuarantined(own), "macOS would stop a copy that still carries the download mark")
            #expect((try? String(contentsOf: tools.appendingPathComponent("yt-dlp.version"), encoding: .utf8)) == row.expectedVersion)
        }
        if row.packed != nil {
            #expect(try String(contentsOf: bundled.appendingPathComponent("yt-dlp"), encoding: .utf8) == packedText, "the packed copy is copied, not moved")
        }
        #expect(!FileManager.default.fileExists(atPath: tools.appendingPathComponent("yt-dlp.new").path))
    }

    // MARK: T18-07

    enum Expected: Sendable, Equatable {
        case updated(String), upToDate(String), failed
    }

    struct UpdateRow: Sendable, CustomTestStringConvertible {
        var label: String
        var mode: String
        var newVersion = ""
        var ownQuarantined = false
        var timeout: TimeInterval = 60
        var expected: Expected
        var testDescription: String { label }
    }

    @Test(arguments: [
        UpdateRow(label: "newer version found", mode: "update", newVersion: "2026.09.01", expected: .updated("2026.09.01")),
        UpdateRow(label: "already up to date", mode: "uptodate", expected: .upToDate(packedVersion)),
        UpdateRow(label: "update fails", mode: "fail", expected: .failed),
        UpdateRow(label: "update hangs", mode: "slow", timeout: 1, expected: .failed),
        UpdateRow(label: "updated copy does not start", mode: "brokenafter", newVersion: "2026.09.01", expected: .failed),
        UpdateRow(label: "result is not newer", mode: "older", newVersion: "2026.07.01", expected: .upToDate(packedVersion)),
        UpdateRow(label: "download mark cleared before running", mode: "uptodate", ownQuarantined: true, expected: .upToDate(packedVersion)),
    ])
    func t18_07_updateOutcomes(row: UpdateRow) async throws {
        let temp = TempDir()
        let fake = FakeSelfUpdatingYtDlp()
        let updater = makeUpdater(temp, timeout: row.timeout)
        let own = updater.toolsDirectory.appendingPathComponent("yt-dlp")
        try fake.install(at: own, version: Self.packedVersion, quarantined: row.ownQuarantined)
        try Data(Self.packedVersion.utf8).write(to: updater.toolsDirectory.appendingPathComponent("yt-dlp.version"))
        let before = try Data(contentsOf: own)
        fake.setMode(row.mode, newVersion: row.newVersion)

        let started = Date()
        let outcome = await updater.updateIfDue(now: Self.base)

        switch row.expected {
        case .failed:
            guard case .failed(let reason) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
            #expect(!reason.isEmpty)
        case .updated(let version): #expect(outcome == .updated(version))
        case .upToDate(let version): #expect(outcome == .upToDate(version))
        }
        let replaced = row.expected == .updated(row.newVersion)
        if replaced {
            #expect(try String(contentsOf: own, encoding: .utf8).contains("VERSION=\"\(row.newVersion)\""))
        } else {
            #expect(try Data(contentsOf: own) == before, "a failed or needless update leaves the working copy alone")
        }
        #expect(try String(contentsOf: updater.toolsDirectory.appendingPathComponent("yt-dlp.version"), encoding: .utf8)
            == (replaced ? row.newVersion : Self.packedVersion))
        let checkSucceeded = row.expected != .failed
        #expect(FileManager.default.fileExists(atPath: updater.stampURL.path) == checkSucceeded, "only a successful check waits a day")
        let left = try FileManager.default.contentsOfDirectory(atPath: updater.toolsDirectory.path).sorted()
        #expect(left == (["yt-dlp", "yt-dlp.version"] + (checkSucceeded ? ["yt-dlp.checked"] : [])).sorted(), "no staging copy is left behind")
        // A hanging update may be stopped while macOS still checks the new file, before it records anything.
        if row.mode != "slow" {
            #expect(fake.runs == [updater.toolsDirectory.appendingPathComponent("yt-dlp.new").path], "the update runs on a copy, never on the working one")
            #expect(fake.arguments == ["--ignore-config", "-U"])
        }
        if row.ownQuarantined { #expect(fake.quarantineSeen == "", "the copy is started without the download mark") }
        if row.mode == "slow" { #expect(Date().timeIntervalSince(started) < 15, "a hanging update is stopped") }
    }

    // MARK: T18-08

    struct IntervalRow: Sendable, CustomTestStringConvertible {
        var label: String
        /// Seconds after `base` of a first, successful check; nil for none.
        var firstCheck: TimeInterval? = 0
        var garbageStamp = false
        var secondCheck: TimeInterval
        var interval: TimeInterval = 86_400
        var runs: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        IntervalRow(label: "an hour later", secondCheck: 3_600, runs: false),
        IntervalRow(label: "just under a day", secondCheck: 86_399, runs: false),
        IntervalRow(label: "exactly a day", secondCheck: 86_400, runs: true),
        IntervalRow(label: "two days later", secondCheck: 172_800, runs: true),
        IntervalRow(label: "right after a success", secondCheck: 0, runs: false),
        IntervalRow(label: "unreadable check time", firstCheck: nil, garbageStamp: true, secondCheck: 0, runs: true),
        IntervalRow(label: "check time in the future (clock moved back)", firstCheck: 86_400, secondCheck: 0, runs: true),
        IntervalRow(label: "shorter interval", secondCheck: 61, interval: 60, runs: true),
    ])
    func t18_08_checksAtMostOncePerInterval(row: IntervalRow) async throws {
        let temp = TempDir()
        let fake = FakeSelfUpdatingYtDlp()
        var updater = makeUpdater(temp)
        updater.interval = row.interval
        try fake.install(at: updater.toolsDirectory.appendingPathComponent("yt-dlp"), version: Self.packedVersion)
        try Data(Self.packedVersion.utf8).write(to: updater.toolsDirectory.appendingPathComponent("yt-dlp.version"))
        fake.setMode("uptodate")
        if let first = row.firstCheck {
            #expect(await updater.updateIfDue(now: Self.base.addingTimeInterval(first)) == .upToDate(Self.packedVersion))
        }
        if row.garbageStamp { try Data("abc".utf8).write(to: updater.stampURL) }
        let runsBefore = fake.runs.count

        let outcome = await updater.updateIfDue(now: Self.base.addingTimeInterval(row.secondCheck))

        #expect(outcome == (row.runs ? .upToDate(Self.packedVersion) : .notDue))
        #expect(fake.runs.count == runsBefore + (row.runs ? 1 : 0))
    }

    @Test func t18_08_failedCheckIsRetriedAtTheNextChance() async throws {
        let temp = TempDir()
        let fake = FakeSelfUpdatingYtDlp()
        let updater = makeUpdater(temp)
        try fake.install(at: updater.toolsDirectory.appendingPathComponent("yt-dlp"), version: Self.packedVersion)
        try Data(Self.packedVersion.utf8).write(to: updater.toolsDirectory.appendingPathComponent("yt-dlp.version"))
        fake.setMode("fail")
        guard case .failed = await updater.updateIfDue(now: Self.base) else { Issue.record("the first check should fail"); return }
        #expect(!FileManager.default.fileExists(atPath: updater.stampURL.path))

        fake.setMode("uptodate")
        #expect(await updater.updateIfDue(now: Self.base.addingTimeInterval(60)) == .upToDate(Self.packedVersion))
        #expect(fake.runs.count == 2)
        #expect(FileManager.default.fileExists(atPath: updater.stampURL.path))
    }

    @Test func t18_08_withoutAnOwnCopyHomebrewIsLeftAlone() async throws {
        let temp = TempDir()
        let homebrew = FakeSelfUpdatingYtDlp()
        let folder = temp.url.appendingPathComponent("homebrew-bin", isDirectory: true)
        try homebrew.install(at: folder.appendingPathComponent("yt-dlp"), version: "2026.01.01")
        homebrew.setMode("update", newVersion: "2026.09.01")
        var updater = makeUpdater(temp)
        updater.environment = ["PATH": "\(folder.path):/usr/bin:/bin"]

        #expect(await updater.updateIfDue(now: Self.base) == .noTool)
        #expect(homebrew.runs.isEmpty)
        let made = (try? FileManager.default.contentsOfDirectory(atPath: updater.toolsDirectory.path)) ?? []
        #expect(made.isEmpty, "no check time is written either")
    }

    // MARK: Helpers

    func makeUpdater(_ temp: TempDir, timeout: TimeInterval = 60) -> YtDlpUpdater {
        var updater = YtDlpUpdater(
            toolsDirectory: temp.url.appendingPathComponent("Tools", isDirectory: true), bundledDirectory: nil, bundledVersionFile: nil,
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/fake-home"]
        )
        updater.timeout = timeout
        return updater
    }

    static let quarantine = "com.apple.quarantine"

    static func writeTool(_ text: String, to url: URL, quarantined: Bool) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if quarantined { markDownloaded(url) }
    }

    /// Sets the mark macOS gives files downloaded through a browser.
    static func markDownloaded(_ url: URL) {
        let value = "0081;6acd9d43;Safari;"
        _ = value.withCString { setxattr(url.path, quarantine, $0, strlen($0), 0, 0) }
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantine, nil, 0, 0, 0) >= 0
    }
}

/// A stand-in for yt-dlp that updates itself like the real one: with `-U` it rewrites its own file with the
/// version in `newversion`; with `--version` it prints the version written in the script. What it saw is recorded
/// in a separate folder, so copies of it elsewhere report there too.
final class FakeSelfUpdatingYtDlp: @unchecked Sendable {
    let control = TempDir()

    func install(at url: URL, version: String, quarantined: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        VERSION="\#(version)"
        CTRL="\#(control.url.path)"
        mode=$(cat "$CTRL/mode" 2>/dev/null)
        new=$(cat "$CTRL/newversion" 2>/dev/null)
        if [ "$1" = "--version" ]; then
          if [ "$mode" = "brokenafter" ] && [ "$VERSION" = "$new" ]; then exit 1; fi
          echo "$VERSION"
          exit 0
        fi
        printf '%s\n' "$@" > "$CTRL/args.txt"
        echo "$0" >> "$CTRL/runs.txt"
        xattr -p com.apple.quarantine "$0" > "$CTRL/quarantine-seen.txt" 2>/dev/null
        case "$mode" in
          update|brokenafter|older)
            sed "s/^VERSION=.*/VERSION=\"$new\"/" "$0" > "$0.tmp" && chmod 755 "$0.tmp" && mv "$0.tmp" "$0"
            echo "Updated yt-dlp to $new"
            exit 0 ;;
          fail) echo "ERROR: Unable to obtain version info (<urlopen error no network>)" >&2; exit 1 ;;
          slow) exec sleep 30 ;;
        esac
        echo "yt-dlp is up to date ($VERSION)"
        """#
        try YtDlpUpdaterTests.writeTool(script, to: url, quarantined: quarantined)
    }

    func setMode(_ mode: String, newVersion: String = "") {
        try? Data(mode.utf8).write(to: control.file("mode"))
        try? Data(newVersion.utf8).write(to: control.file("newversion"))
    }

    private func recorded(_ name: String) -> String? {
        try? String(contentsOf: control.file(name), encoding: .utf8)
    }

    /// Where the tool ran from, once per `-U` run.
    var runs: [String] { (recorded("runs.txt") ?? "").split(separator: "\n").map(String.init) }
    var arguments: [String] { (recorded("args.txt") ?? "").split(separator: "\n").map(String.init) }
    var quarantineSeen: String? { recorded("quarantine-seen.txt") }
}
