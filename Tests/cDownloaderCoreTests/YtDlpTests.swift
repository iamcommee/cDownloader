import Foundation
import Testing
@testable import cDownloaderCore

/// YouTube downloads through yt-dlp: link recognition, the tool's arguments and output, and the runner.
@Suite struct YtDlpTests {
    static let id = "dQw4w9WgXcQ"
    static let list = "PLabc_12-x"

    // MARK: T17-01

    struct LinkRow: Sendable, CustomTestStringConvertible {
        var label: String
        var url: String
        var expected: YouTubeLink?
        var testDescription: String { label }
    }

    @Test(arguments: [
        LinkRow(label: "watch", url: "https://www.youtube.com/watch?v=\(id)", expected: .video(id: id)),
        LinkRow(label: "watch with list", url: "https://www.youtube.com/watch?v=\(id)&list=\(list)", expected: .video(id: id)),
        LinkRow(label: "v not first", url: "https://www.youtube.com/watch?feature=share&v=\(id)", expected: .video(id: id)),
        LinkRow(label: "no www", url: "https://youtube.com/watch?v=\(id)", expected: .video(id: id)),
        LinkRow(label: "mobile", url: "https://m.youtube.com/watch?v=\(id)", expected: .video(id: id)),
        LinkRow(label: "music", url: "https://music.youtube.com/watch?v=\(id)", expected: .video(id: id)),
        LinkRow(label: "nocookie embed", url: "https://www.youtube-nocookie.com/embed/\(id)", expected: .video(id: id)),
        LinkRow(label: "nocookie without www", url: "https://youtube-nocookie.com/embed/\(id)", expected: .video(id: id)),
        LinkRow(label: "youtu.be", url: "https://youtu.be/\(id)?t=10", expected: .video(id: id)),
        LinkRow(label: "shorts", url: "https://www.youtube.com/shorts/\(id)", expected: .video(id: id)),
        LinkRow(label: "live", url: "https://www.youtube.com/live/\(id)", expected: .video(id: id)),
        LinkRow(label: "embed", url: "https://www.youtube.com/embed/\(id)", expected: .video(id: id)),
        LinkRow(label: "old v path", url: "https://www.youtube.com/v/\(id)", expected: .video(id: id)),
        LinkRow(label: "uppercase host", url: "HTTPS://WWW.YouTube.COM/watch?v=\(id)", expected: .video(id: id)),
        LinkRow(label: "http scheme", url: "http://youtu.be/\(id)", expected: .video(id: id)),
        LinkRow(label: "playlist", url: "https://www.youtube.com/playlist?list=\(list)", expected: .playlist(id: list)),
        LinkRow(label: "embedded playlist", url: "https://www.youtube.com/embed/videoseries?list=\(list)", expected: .playlist(id: list)),
        LinkRow(label: "playlist id of 2", url: "https://www.youtube.com/playlist?list=PL", expected: .playlist(id: "PL")),
        LinkRow(label: "playlist id of 1", url: "https://www.youtube.com/playlist?list=P", expected: nil),
        LinkRow(label: "playlist without list", url: "https://www.youtube.com/playlist", expected: nil),
        LinkRow(label: "id of 10", url: "https://www.youtube.com/watch?v=abcdefghij", expected: nil),
        LinkRow(label: "id of 12", url: "https://www.youtube.com/watch?v=abcdefghijkl", expected: nil),
        LinkRow(label: "id with bad char", url: "https://www.youtube.com/watch?v=abc!defghij", expected: nil),
        LinkRow(label: "watch without v", url: "https://www.youtube.com/watch", expected: nil),
        LinkRow(label: "channel", url: "https://www.youtube.com/@name", expected: nil),
        LinkRow(label: "home", url: "https://www.youtube.com/", expected: nil),
        LinkRow(label: "search", url: "https://www.youtube.com/results?search_query=x", expected: nil),
        LinkRow(label: "channel id", url: "https://www.youtube.com/channel/UC1", expected: nil),
        LinkRow(label: "look-alike prefix", url: "https://notyoutube.com/watch?v=\(id)", expected: nil),
        LinkRow(label: "look-alike suffix", url: "https://youtube.com.evil.example/watch?v=\(id)", expected: nil),
        LinkRow(label: "look-alike short", url: "https://evilyoutu.be/\(id)", expected: nil),
        LinkRow(label: "look-alike short suffix", url: "https://youtu.be.evil.com/\(id)", expected: nil),
        LinkRow(label: "ftp scheme", url: "ftp://youtube.com/watch?v=\(id)", expected: nil),
        LinkRow(label: "file scheme", url: "file:///x", expected: nil),
        LinkRow(label: "no scheme", url: "youtube.com/watch?v=\(id)", expected: nil),
    ])
    func t17_01_classifiesYouTubeLinks(row: LinkRow) throws {
        let url = try #require(URL(string: row.url))
        #expect(YouTubeLinks.classify(url) == row.expected)
    }

    @Test func t17_01_watchURL() {
        #expect(YouTubeLinks.watchURL(id: Self.id).absoluteString == "https://www.youtube.com/watch?v=\(Self.id)")
    }

    // MARK: T19-01, T19-02 (Facebook)

    struct FacebookRow: Sendable, CustomTestStringConvertible {
        var label: String
        var url: String
        var expected: Bool
        var testDescription: String { label }
    }

    /// The same addresses are checked in the add-on (Extension/rules.test.js, T19-07), so both sides agree.
    @Test(arguments: [
        FacebookRow(label: "watch", url: "https://www.facebook.com/watch?v=1", expected: true),
        FacebookRow(label: "watch with slash", url: "https://www.facebook.com/watch/?v=1", expected: true),
        FacebookRow(label: "mobile watch", url: "https://m.facebook.com/watch/?v=1", expected: true),
        FacebookRow(label: "live", url: "https://web.facebook.com/watch/live/?v=1", expected: true),
        FacebookRow(label: "video.php without www", url: "https://facebook.com/video.php?v=1", expected: true),
        FacebookRow(label: "video/video.php", url: "https://www.facebook.com/video/video.php?v=1", expected: true),
        FacebookRow(label: "page video", url: "https://www.facebook.com/page/videos/123", expected: true),
        FacebookRow(label: "page video with slash", url: "https://www.facebook.com/page/videos/123/", expected: true),
        FacebookRow(label: "page video with slug", url: "https://www.facebook.com/page/videos/some-slug/123", expected: true),
        FacebookRow(label: "mbasic", url: "https://mbasic.facebook.com/page/videos/123", expected: true),
        FacebookRow(label: "business", url: "https://business.facebook.com/page/videos/123", expected: true),
        FacebookRow(label: "reel", url: "https://www.facebook.com/reel/123", expected: true),
        FacebookRow(label: "shared video", url: "https://www.facebook.com/share/v/AbC1/", expected: true),
        FacebookRow(label: "shared reel", url: "https://www.facebook.com/share/r/AbC1", expected: true),
        FacebookRow(label: "embedded player", url: "https://www.facebook.com/plugins/video.php?href=https%3A%2F%2Fwww.facebook.com%2Fpage%2Fvideos%2F123%2F", expected: true),
        FacebookRow(label: "fb.watch", url: "https://fb.watch/AbC1/", expected: true),
        FacebookRow(label: "http scheme", url: "http://www.facebook.com/reel/123", expected: true),
        FacebookRow(label: "uppercase host", url: "HTTPS://WWW.FaceBook.COM/reel/123", expected: true),
        FacebookRow(label: "home", url: "https://www.facebook.com/", expected: false),
        FacebookRow(label: "profile", url: "https://www.facebook.com/somepage", expected: false),
        FacebookRow(label: "post", url: "https://www.facebook.com/page/posts/123", expected: false),
        FacebookRow(label: "photo", url: "https://www.facebook.com/photo.php?fbid=1", expected: false),
        FacebookRow(label: "shared post", url: "https://www.facebook.com/share/p/AbC1", expected: false),
        FacebookRow(label: "videos without a page", url: "https://www.facebook.com/videos/", expected: false),
        FacebookRow(label: "videos tab", url: "https://www.facebook.com/page/videos/", expected: false),
        FacebookRow(label: "videos slug without id", url: "https://www.facebook.com/page/videos/some-slug", expected: false),
        FacebookRow(label: "watch without v", url: "https://www.facebook.com/watch/", expected: false),
        FacebookRow(label: "watch with empty v", url: "https://www.facebook.com/watch/?v=", expected: false),
        FacebookRow(label: "reel without id", url: "https://www.facebook.com/reel/", expected: false),
        FacebookRow(label: "reel with letters", url: "https://www.facebook.com/reel/abc", expected: false),
        FacebookRow(label: "share without code", url: "https://www.facebook.com/share/v/", expected: false),
        FacebookRow(label: "embedded player without href", url: "https://www.facebook.com/plugins/video.php", expected: false),
        FacebookRow(label: "fb.watch without code", url: "https://fb.watch/", expected: false),
        FacebookRow(label: "look-alike prefix (guard)", url: "https://evilfacebook.com/watch/?v=1", expected: false),
        FacebookRow(label: "look-alike suffix (guard)", url: "https://facebook.com.evil.example/watch/?v=1", expected: false),
        FacebookRow(label: "look-alike short (guard)", url: "https://evilfb.watch/AbC1", expected: false),
        FacebookRow(label: "look-alike short suffix (guard)", url: "https://fb.watch.evil.example/AbC1", expected: false),
        FacebookRow(label: "ftp scheme (guard)", url: "ftp://www.facebook.com/reel/123", expected: false),
        FacebookRow(label: "file scheme (guard)", url: "file:///reel/123", expected: false),
        FacebookRow(label: "video piece (guard)", url: "https://video.xx.fbcdn.net/v/a.mp4", expected: false),
        FacebookRow(label: "YouTube (guard)", url: "https://www.youtube.com/watch?v=\(id)", expected: false),
    ])
    func t19_01_recognizesFacebookVideoLinks(row: FacebookRow) throws {
        let url = try #require(URL(string: row.url))
        #expect(FacebookLinks.isVideo(url) == row.expected)
    }

    struct SiteRow: Sendable, CustomTestStringConvertible {
        var label: String
        var url: String
        var expected: WebVideoSite?
        var testDescription: String { label }
    }

    @Test(arguments: [
        SiteRow(label: "YouTube video (guard)", url: "https://www.youtube.com/watch?v=\(id)", expected: .youtube),
        SiteRow(label: "YouTube playlist (guard)", url: "https://www.youtube.com/playlist?list=\(list)", expected: .youtube),
        SiteRow(label: "Facebook reel", url: "https://www.facebook.com/reel/123", expected: .facebook),
        SiteRow(label: "fb.watch", url: "https://fb.watch/AbC1", expected: .facebook),
        SiteRow(label: "Facebook profile", url: "https://www.facebook.com/somepage", expected: nil),
        SiteRow(label: "plain file", url: "https://example.com/a.mp4", expected: nil),
    ])
    func t19_02_findsTheVideoSite(row: SiteRow) throws {
        let url = try #require(URL(string: row.url))
        #expect(WebVideoLinks.site(of: url) == row.expected)
    }

    /// The sign-in file only ever names the site the address belongs to.
    @Test func t19_02_cookieDomains() {
        #expect(WebVideoSite.youtube.cookieDomain == ".youtube.com")
        #expect(WebVideoSite.facebook.cookieDomain == ".facebook.com")
    }

    // MARK: T17-02

    struct FormatRow: Sendable, CustomTestStringConvertible {
        var label: String
        var quality: VideoQuality
        var ffmpeg: Bool
        var expected: [String]
        var testDescription: String { label }
    }

    static let sorting = ["-S", "res,fps,vcodec:h264,acodec:aac", "--merge-output-format", "mp4/mkv"]
    static func capped(_ height: Int) -> [String] {
        ["-f", "bv*[height<=\(height)]+ba/b[height<=\(height)]/bv*+ba/b"] + sorting
    }

    @Test(arguments: [
        FormatRow(label: "best with ffmpeg", quality: .best, ffmpeg: true, expected: ["-f", "bv*+ba/b"] + sorting),
        FormatRow(label: "1080 with ffmpeg", quality: .p1080, ffmpeg: true, expected: capped(1080)),
        FormatRow(label: "720 with ffmpeg", quality: .p720, ffmpeg: true, expected: capped(720)),
        FormatRow(label: "480 with ffmpeg", quality: .p480, ffmpeg: true, expected: capped(480)),
        FormatRow(label: "360 with ffmpeg", quality: .p360, ffmpeg: true, expected: capped(360)),
        FormatRow(label: "audio with ffmpeg", quality: .audio, ffmpeg: true, expected: ["-f", "ba/b", "-x", "--audio-format", "m4a"]),
        FormatRow(label: "best without ffmpeg", quality: .best, ffmpeg: false, expected: ["-f", "b"]),
        FormatRow(label: "1080 without ffmpeg", quality: .p1080, ffmpeg: false, expected: ["-f", "b[height<=1080]/b"]),
        FormatRow(label: "720 without ffmpeg", quality: .p720, ffmpeg: false, expected: ["-f", "b[height<=720]/b"]),
        FormatRow(label: "480 without ffmpeg", quality: .p480, ffmpeg: false, expected: ["-f", "b[height<=480]/b"]),
        FormatRow(label: "360 without ffmpeg", quality: .p360, ffmpeg: false, expected: ["-f", "b[height<=360]/b"]),
        FormatRow(label: "audio without ffmpeg", quality: .audio, ffmpeg: false, expected: ["-f", "ba[ext=m4a]/ba/b"]),
    ])
    func t17_02_formatArgumentsPerQuality(row: FormatRow) {
        #expect(YtDlp.formatArguments(quality: row.quality, ffmpegPath: row.ffmpeg ? "/opt/homebrew/bin/ffmpeg" : nil) == row.expected)
    }

    // MARK: T17-04

    struct FailureRow: Sendable, CustomTestStringConvertible {
        var label: String
        var stderr: String
        var code: Int32
        var expected: String
        var testDescription: String { label }
    }

    @Test(arguments: [
        FailureRow(label: "extractor prefix", stderr: "ERROR: [youtube] abc123def45: Video unavailable\n", code: 1, expected: "Video unavailable"),
        FailureRow(label: "no extractor prefix", stderr: "ERROR: Sign in to confirm your age", code: 1, expected: "Sign in to confirm your age"),
        FailureRow(label: "last error wins", stderr: "WARNING: slow\nERROR: first\nWARNING: again\nERROR: [youtube] x: second\n", code: 1, expected: "second"),
        FailureRow(label: "trailing blank lines and CRLF", stderr: "ERROR: [generic] y: Gone away\r\n\r\n\n", code: 1, expected: "Gone away"),
        FailureRow(label: "no error line", stderr: "something odd\n", code: 2, expected: "yt-dlp stopped (code 2)"),
        FailureRow(label: "empty", stderr: "", code: 1, expected: "yt-dlp stopped (code 1)"),
        FailureRow(label: "warning only", stderr: "WARNING: [youtube] slow\n", code: 1, expected: "yt-dlp stopped (code 1)"),
        FailureRow(label: "bot check, straight apostrophe", stderr: "ERROR: [youtube] \(id): Sign in to confirm you're not a bot. Use --cookies-from-browser\n", code: 1, expected: YtDlp.botCheckMessage),
        FailureRow(label: "bot check, curly apostrophe", stderr: "ERROR: [youtube] \(id): Sign in to confirm you\u{2019}re not a bot.\n", code: 1, expected: YtDlp.botCheckMessage),
        FailureRow(label: "bot check not on the last error line", stderr: "ERROR: [youtube] \(id): Sign in to confirm you\u{2019}re not a bot.\nERROR: something else\n", code: 1, expected: YtDlp.botCheckMessage),
        FailureRow(label: "too many requests stays raw", stderr: "ERROR: [youtube] \(id): HTTP Error 429: Too Many Requests\n", code: 1, expected: "HTTP Error 429: Too Many Requests"),
        // T19-10
        FailureRow(label: "Facebook sign-in needed", stderr: "ERROR: [facebook] 123: This video is only available for registered users. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  for how to manually pass cookies\n", code: 1, expected: YtDlp.signInMessage),
        FailureRow(label: "sign-in not on the last line", stderr: "WARNING: [facebook] slow\nERROR: [facebook] 123: This video is only available for registered users.\n[download] 0%\n", code: 1, expected: YtDlp.signInMessage),
        FailureRow(label: "sign-in without the error prefix", stderr: "This video is only available for registered users\n", code: 1, expected: YtDlp.signInMessage),
        FailureRow(label: "bot check wins over sign-in (guard)", stderr: "ERROR: [youtube] \(id): only available for registered users\nERROR: [youtube] \(id): Sign in to confirm you're not a bot.\n", code: 1, expected: YtDlp.botCheckMessage),
        FailureRow(label: "other Facebook error stays raw (guard)", stderr: "ERROR: [facebook] 123: Cannot parse data\n", code: 1, expected: "Cannot parse data"),
    ])
    func t17_04_failureMessages(row: FailureRow) {
        #expect(YtDlp.failureMessage(stderr: row.stderr, exitCode: row.code) == row.expected)
    }

    /// T18-04: yt-dlp now comes with the app, so the advice is to reinstall it first.
    /// T19-06: it does the Facebook downloads too; the bot check stays YouTube's own.
    @Test func t17_04_fixedMessages() {
        #expect(YtDlp.missingMessage == "YouTube and Facebook downloads need yt-dlp, which comes with cDownloader. Reinstall cDownloader, or install it with Homebrew: brew install yt-dlp")
        #expect(YtDlp.botCheckMessage == "YouTube asked to confirm you're not a bot. Start the download from the browser add-on, which passes your YouTube sign-in, or choose a browser under Settings > Video Sites.")
        #expect(YtDlp.signInMessage.contains("signed in") && YtDlp.signInMessage.contains("Settings > Video Sites"))
    }

    // MARK: T17-07 (search path)

    struct PathRow: Sendable, CustomTestStringConvertible {
        var label: String
        var executable: String
        var inherited: String?
        /// T18-03: the folder of the tools packed inside the app.
        var bundled: String?
        var expected: String
        var testDescription: String { label }
    }

    /// An app opened from Finder only has the system folders on its search path, so yt-dlp would miss deno.
    /// T18-03: yt-dlp runs from the app's own folder, so the packed deno and ffmpeg come right after it.
    @Test(arguments: [
        PathRow(label: "app opened from Finder", executable: "/T/yt-dlp", inherited: "/usr/bin:/bin:/usr/sbin:/sbin",
                expected: "/T:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"),
        PathRow(label: "tool in the Homebrew folder", executable: "/opt/homebrew/bin/yt-dlp", inherited: "/usr/bin:/bin",
                expected: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
        PathRow(label: "inherited path already has Homebrew", executable: "/T/yt-dlp", inherited: "/opt/homebrew/bin:/usr/bin",
                expected: "/T:/opt/homebrew/bin:/usr/local/bin:/usr/bin"),
        PathRow(label: "no inherited path", executable: "/T/yt-dlp", inherited: nil, expected: "/T:/opt/homebrew/bin:/usr/local/bin"),
        PathRow(label: "empty inherited path", executable: "/T/yt-dlp", inherited: "", expected: "/T:/opt/homebrew/bin:/usr/local/bin"),
        PathRow(label: "empty pieces dropped", executable: "/T/yt-dlp", inherited: "/usr/bin::/bin:", expected: "/T:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
        PathRow(label: "T18-03 packed folder after the tool's own", executable: "/T/yt-dlp", inherited: "/usr/bin", bundled: "/App/Helpers",
                expected: "/T:/App/Helpers:/opt/homebrew/bin:/usr/local/bin:/usr/bin"),
        PathRow(label: "T18-03 tool inside the packed folder", executable: "/App/Helpers/yt-dlp", inherited: "/usr/bin", bundled: "/App/Helpers",
                expected: "/App/Helpers:/opt/homebrew/bin:/usr/local/bin:/usr/bin"),
        PathRow(label: "T18-03 packed folder already inherited", executable: "/T/yt-dlp", inherited: "/usr/bin:/App/Helpers", bundled: "/App/Helpers",
                expected: "/T:/App/Helpers:/opt/homebrew/bin:/usr/local/bin:/usr/bin"),
        PathRow(label: "T18-03 empty packed folder dropped", executable: "/T/yt-dlp", inherited: "/usr/bin", bundled: "",
                expected: "/T:/opt/homebrew/bin:/usr/local/bin:/usr/bin"),
        PathRow(label: "T18-03 packed folder, no inherited path", executable: "/T/yt-dlp", inherited: nil, bundled: "/App/Helpers",
                expected: "/T:/App/Helpers:/opt/homebrew/bin:/usr/local/bin"),
    ])
    func t17_07_searchPathFindsHomebrewTools(row: PathRow) {
        #expect(YtDlp.searchPath(executable: row.executable, inherited: row.inherited, bundled: row.bundled) == row.expected)
    }

    // MARK: T18-01, T18-02: where the tools are found

    struct LocateRow: Sendable, CustomTestStringConvertible {
        var label: String
        /// Which places hold the tool: "own", "bundled", "fallback1", "fallback2". A name ending in "-" is not
        /// runnable, one ending in "/" is a folder.
        var present: [String]
        var ownFolder = true
        var bundledFolder = true
        /// The place expected, or nil for none.
        var expected: String?
        var testDescription: String { label }
    }

    /// Lays out the places a row names in a fresh folder; returns the folders and the fallback paths.
    func layOut(_ row: LocateRow, tool: String, in temp: TempDir) throws -> (own: URL?, bundled: URL?, fallbacks: [String], places: [String: String]) {
        let fileManager = FileManager.default
        var places: [String: String] = [:]
        for place in ["own", "bundled", "fallback1", "fallback2"] {
            let folder = temp.url.appendingPathComponent(place, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            places[place] = folder.appendingPathComponent(tool).path
        }
        for entry in row.present {
            let name = entry.trimmingCharacters(in: CharacterSet(charactersIn: "-/"))
            let path = places[name]!
            if entry.hasSuffix("/") {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            } else {
                try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
                try fileManager.setAttributes([.posixPermissions: entry.hasSuffix("-") ? 0o644 : 0o755], ofItemAtPath: path)
            }
        }
        let own = row.ownFolder ? temp.url.appendingPathComponent("own", isDirectory: true) : nil
        let bundled = row.bundledFolder ? temp.url.appendingPathComponent("bundled", isDirectory: true) : nil
        return (own, bundled, [places["fallback1"]!, places["fallback2"]!], places)
    }

    /// The app's own updated copy comes first, then the one packed inside the app, then Homebrew's.
    @Test(arguments: [
        LocateRow(label: "all three runnable", present: ["own", "bundled", "fallback1"], expected: "own"),
        LocateRow(label: "own copy missing", present: ["bundled", "fallback1"], expected: "bundled"),
        LocateRow(label: "own copy not runnable", present: ["own-", "bundled"], expected: "bundled"),
        LocateRow(label: "packed copy not runnable", present: ["bundled-", "fallback1"], expected: "fallback1"),
        LocateRow(label: "only Homebrew's", present: ["fallback1"], expected: "fallback1"),
        LocateRow(label: "first of two fallbacks wins", present: ["fallback1", "fallback2"], expected: "fallback1"),
        LocateRow(label: "no own or packed folder", present: ["fallback2"], ownFolder: false, bundledFolder: false, expected: "fallback2"),
        LocateRow(label: "nothing anywhere", present: [], expected: nil),
        LocateRow(label: "a folder named yt-dlp is skipped (guard)", present: ["own/", "bundled"], expected: "bundled"),
    ])
    func t18_01_locateYtDlpOrder(row: LocateRow) throws {
        let temp = TempDir()
        let layout = try layOut(row, tool: "yt-dlp", in: temp)
        let found = YtDlp.locate(own: layout.own, bundled: layout.bundled, fallbacks: layout.fallbacks)
        #expect(found == row.expected.map { layout.places[$0]! })
    }

    /// ffmpeg packed inside the app comes before Homebrew's.
    @Test(arguments: [
        LocateRow(label: "packed beats Homebrew", present: ["bundled", "fallback1"], expected: "bundled"),
        LocateRow(label: "packed not runnable", present: ["bundled-", "fallback1"], expected: "fallback1"),
        LocateRow(label: "no packed folder", present: ["fallback1"], bundledFolder: false, expected: "fallback1"),
        LocateRow(label: "packed folder without ffmpeg", present: ["fallback2"], expected: "fallback2"),
        LocateRow(label: "first of two fallbacks wins", present: ["fallback1", "fallback2"], expected: "fallback1"),
        LocateRow(label: "nothing anywhere", present: [], expected: nil),
    ])
    func t18_02_locateFFmpegOrder(row: LocateRow) throws {
        let temp = TempDir()
        let layout = try layOut(row, tool: "ffmpeg", in: temp)
        #expect(FFmpeg.locate(bundled: layout.bundled, fallbacks: layout.fallbacks) == row.expected.map { layout.places[$0]! })
    }

    /// T18-02 guard: with nothing packed (as in tests), the defaults still look in Homebrew's folders.
    @Test func t18_02_locateFFmpegDefaults() {
        let found = FFmpeg.locate()
        #expect(found == nil || FileManager.default.isExecutableFile(atPath: found!))
    }

    // MARK: T17-03

    struct ArgumentsRow: Sendable, CustomTestStringConvertible {
        var label: String
        var url = "https://www.youtube.com/watch?v=\(YtDlpTests.id)"
        var ffmpeg: String?
        var speedLimit: Int64?
        var cookiesFile: String?
        var browser: String?
        /// Arguments expected between the format arguments and the address.
        var extra: [String]
        var testDescription: String { label }
    }

    static let work = URL(fileURLWithPath: "/tmp/work folder/x.ytdlp", isDirectory: true)
    static let fixedArguments = [
        "--ignore-config", "--no-playlist", "--newline", "--progress", "--color", "never",
        "--progress-template", "download:[cdl] %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
        "--print", "before_dl:[cdl-title] %(title)s",
        "--print", "after_move:[cdl-file] %(filepath)s",
        "-P", "/tmp/work folder/x.ytdlp", "-o", "%(title).150B.%(ext)s",
    ]

    @Test(arguments: [
        ArgumentsRow(label: "plain", extra: []),
        ArgumentsRow(label: "speed limit", speedLimit: 500_000, extra: ["--limit-rate", "500000"]),
        ArgumentsRow(label: "ffmpeg", ffmpeg: "/opt/homebrew/bin/ffmpeg", extra: ["--ffmpeg-location", "/opt/homebrew/bin/ffmpeg"]),
        ArgumentsRow(label: "odd address characters (guard)", url: "https://youtu.be/\(YtDlpTests.id)?si=a%20b&t=1", extra: []),
        ArgumentsRow(label: "cookie file", cookiesFile: "/tmp/w/cookies.txt", extra: ["--cookies", "/tmp/w/cookies.txt"]),
        ArgumentsRow(label: "browser cookies", browser: "chrome", extra: ["--cookies-from-browser", "chrome"]),
        ArgumentsRow(label: "cookie file wins over browser", cookiesFile: "/tmp/w/cookies.txt", browser: "chrome", extra: ["--cookies", "/tmp/w/cookies.txt"]),
        ArgumentsRow(label: "empty browser name means none", browser: "", extra: []),
        ArgumentsRow(label: "everything", ffmpeg: "/f", speedLimit: 1, cookiesFile: "/c", browser: "safari",
                     extra: ["--ffmpeg-location", "/f", "--limit-rate", "1", "--cookies", "/c"]),
    ])
    func t17_03_assemblesArguments(row: ArgumentsRow) throws {
        let url = try #require(URL(string: row.url))
        let arguments = YtDlp.arguments(
            url: url, quality: .p720, workFolder: Self.work, ffmpegPath: row.ffmpeg, speedLimit: row.speedLimit,
            cookiesFile: row.cookiesFile.map { URL(fileURLWithPath: $0) }, cookiesFromBrowser: row.browser
        )
        let format = YtDlp.formatArguments(quality: .p720, ffmpegPath: row.ffmpeg)
        #expect(arguments == Self.fixedArguments + format + row.extra + ["--", url.absoluteString])
    }

    // MARK: T17-16

    struct CookieRow: Sendable, CustomTestStringConvertible {
        var label: String
        var header: String?
        /// Expected (name, value) lines; nil means no file at all.
        var pairs: [(String, String)]?
        /// T19-03: the site whose sign-in this is.
        var site = WebVideoSite.youtube
        var testDescription: String { label }
    }

    @Test(arguments: [
        CookieRow(label: "single pair", header: "a=1", pairs: [("a", "1")]),
        CookieRow(label: "two pairs", header: "a=1; b=2", pairs: [("a", "1"), ("b", "2")]),
        CookieRow(label: "loose spaces", header: "a=1 ;  b=2", pairs: [("a", "1"), ("b", "2")]),
        CookieRow(label: "value with equals sign", header: "a=1; b=x=y", pairs: [("a", "1"), ("b", "x=y")]),
        CookieRow(label: "empty value kept", header: "a=", pairs: [("a", "")]),
        CookieRow(label: "empty name skipped", header: "=v; a=1", pairs: [("a", "1")]),
        CookieRow(label: "pair without equals skipped", header: "junk; a=1", pairs: [("a", "1")]),
        CookieRow(label: "tab skipped", header: "a=1\t2; b=2", pairs: [("b", "2")]),
        CookieRow(label: "line break cannot add a line", header: "a=1\n.evil.com\tTRUE\t/\tTRUE\t0\tx\ty; c=3", pairs: [("c", "3")]),
        CookieRow(label: "carriage return skipped", header: "a=1\r; c=3", pairs: [("c", "3")]),
        CookieRow(label: "duplicate names kept in order", header: "a=1; a=2", pairs: [("a", "1"), ("a", "2")]),
        CookieRow(label: "nil", header: nil, pairs: nil),
        CookieRow(label: "empty", header: "", pairs: nil),
        CookieRow(label: "only separators", header: " ;; ", pairs: nil),
        CookieRow(label: "nothing valid", header: "=1; ;", pairs: nil),
        // T19-03
        CookieRow(label: "Facebook sign-in", header: "c_user=1; xs=2", pairs: [("c_user", "1"), ("xs", "2")], site: .facebook),
        CookieRow(label: "Facebook, nothing usable (guard)", header: "", pairs: nil, site: .facebook),
    ])
    func t17_16_cookieFileText(row: CookieRow) {
        let text = YtDlp.cookieFile(header: row.header, site: row.site)
        guard let pairs = row.pairs else {
            #expect(text == nil)
            return
        }
        if row.site != .youtube { #expect(text?.contains("youtube") == false, "a sign-in never names another site") }
        let domain = row.site == .youtube ? ".youtube.com" : ".facebook.com"
        let lines = pairs.map { "\(domain)\tTRUE\t/\tTRUE\t4102444800\t\($0.0)\t\($0.1)" }
        #expect(text == (["# Netscape HTTP Cookie File"] + lines).joined(separator: "\n") + "\n")
        for line in text?.split(separator: "\n").dropFirst() ?? [] {
            #expect(line.split(separator: "\t", omittingEmptySubsequences: false).count == 7)
        }
    }

    // MARK: T17-05

    struct ProgressRow: Sendable, CustomTestStringConvertible {
        var label: String
        var lines: [String]
        /// The expected update after each line; nil where the line is not a progress line.
        var expected: [YtDlpProgress.Update?]
        var testDescription: String { label }
    }

    static func update(_ downloaded: Int64, _ total: Int64?, _ speed: Double) -> YtDlpProgress.Update {
        YtDlpProgress.Update(downloadedBytes: downloaded, totalBytes: total, bytesPerSecond: speed)
    }

    @Test(arguments: [
        ProgressRow(label: "total known", lines: ["[cdl] 500 1000 NA 250.5"], expected: [update(500, 1000, 250.5)]),
        ProgressRow(label: "total from estimate", lines: ["[cdl] 500 NA 2000 100"], expected: [update(500, 2000, 100)]),
        ProgressRow(label: "total wins over estimate", lines: ["[cdl] 5 10 20 1"], expected: [update(5, 10, 1)]),
        ProgressRow(label: "only downloaded known", lines: ["[cdl] 500 NA NA NA"], expected: [update(500, nil, 0)]),
        ProgressRow(label: "speed unknown", lines: ["[cdl] 1 2 NA NA"], expected: [update(1, 2, 0)]),
        ProgressRow(label: "float strings", lines: ["[cdl] 500.0 1000.0 NA 1.5e3"], expected: [update(500, 1000, 1500)]),
        ProgressRow(label: "two parts add up", lines: ["[cdl] 100 100 NA 5", "[cdl] 10 50 NA 5", "[cdl] 50 50 NA 5"],
                    expected: [update(100, 100, 5), update(110, 150, 5), update(150, 150, 5)]),
        ProgressRow(label: "one part grows (guard)", lines: ["[cdl] 10 100 NA 1", "[cdl] 20 100 NA 1", "[cdl] 30 100 NA 1"],
                    expected: [update(10, 100, 1), update(20, 100, 1), update(30, 100, 1)]),
        ProgressRow(label: "same value is not a new part", lines: ["[cdl] 100 200 NA 1", "[cdl] 100 200 NA 1"],
                    expected: [update(100, 200, 1), update(100, 200, 1)]),
        ProgressRow(label: "other lines", lines: ["[download] 5%", "", "[cdl-title] x", "garbage [cdl] 1"], expected: [nil, nil, nil, nil]),
        ProgressRow(label: "malformed", lines: ["[cdl] abc 1 2 3", "[cdl] 1 2"], expected: [nil, nil]),
    ])
    func t17_05_progressLines(row: ProgressRow) {
        var progress = YtDlpProgress()
        let results = row.lines.map { progress.consume($0) }
        #expect(results == row.expected)
    }

    @Test func t17_05_titleAndFileLines() {
        #expect(YtDlpProgress.title(from: "[cdl-title] My Video") == "My Video")
        #expect(YtDlpProgress.title(from: "[cdl-title] Größe: ½ ★ 日本") == "Größe: ½ ★ 日本")
        #expect(YtDlpProgress.title(from: "[cdl-title]") == nil)
        #expect(YtDlpProgress.title(from: "[cdl-title] ") == nil)
        #expect(YtDlpProgress.title(from: "[cdl] 1 2 3 4") == nil)
        #expect(YtDlpProgress.file(from: "[cdl-file] /a/b c.mp4") == "/a/b c.mp4")
        #expect(YtDlpProgress.file(from: "[cdl-title] /a") == nil)
        #expect(YtDlpProgress.file(from: "[cdl-file]") == nil)
    }

    // MARK: T17-06

    @Test func t17_06_parsesFlatPlaylistOutput() {
        let a = "aaaaaaaaaaa", b = "bbbbbbbbbbb", c = "ccccccccccc", d = "ddddddddddd"
        let output = [
            "\(a)\tFirst",
            "\(b)\tTitle\twith tab",
            "short\tTen chars",
            "\(c)\t[Private video]",
            "\(d)\t[Deleted video]",
            "\(a)\tFirst again",
            "",
            "\(c)\r",
            "\(d)\tNA",
        ].joined(separator: "\n") + "\n"
        let entries = YtDlpPlaylist.parseFlat(output)
        #expect(entries == [
            YtDlpPlaylist.Entry(id: a, title: "First"),
            YtDlpPlaylist.Entry(id: b, title: "Title\twith tab"),
            YtDlpPlaylist.Entry(id: c, title: ""),
            YtDlpPlaylist.Entry(id: d, title: ""),
        ])
        #expect(YtDlpPlaylist.parseFlat("") == [])
    }

    // MARK: T17-07, T17-08, T17-09, T17-17: the runner, with a stand-in for yt-dlp

    static let finderPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let secret = "SECRETVAL123"

    struct Run {
        var item: DownloadItem
        var recorder: JobRecorder
        var runner: DownloadRunner
        var workFolder: URL
    }

    func makeEngine(_ fake: FakeYtDlp?, temp: TempDir, path: String? = nil, browser: String? = nil, stopGrace: TimeInterval = 5) -> DownloadEngine {
        var configuration = EngineConfiguration(temporaryDirectory: temp.url.appendingPathComponent("tmp", isDirectory: true))
        configuration.ytDlpPath = path ?? fake?.path
        configuration.ffmpegPath = nil
        configuration.ytDlpCookiesBrowser = browser
        configuration.toolEnvironment = ["PATH": Self.finderPath, "HOME": "/tmp/fake-home"]
        configuration.toolStopGrace = stopGrace
        return DownloadEngine(configuration: configuration, secrets: InMemorySecretStore())
    }

    func videoItem(_ out: TempDir, url: String = "https://www.youtube.com/watch?v=\(YtDlpTests.id)", quality: VideoQuality = .p720,
                   fileName: String = "", cookies: String? = nil) -> DownloadItem {
        var item = DownloadItem(url: URL(string: url)!, fileName: fileName, directory: out.url.appendingPathComponent("out").path)
        item.kind = .webVideo(quality: quality)
        item.cookies = cookies
        return item
    }

    func start(_ engine: DownloadEngine, _ item: DownloadItem) -> Run {
        let recorder = JobRecorder()
        let runner = engine.makeRunner(for: item) { recorder.handle($0) }
        runner.start()
        let work = engine.currentConfiguration.temporaryDirectory.appendingPathComponent("\(item.id.uuidString).ytdlp", isDirectory: true)
        return Run(item: item, recorder: recorder, runner: runner, workFolder: work)
    }

    struct SuccessRow: Sendable, CustomTestStringConvertible {
        var label: String
        var fileName = ""
        var quality = VideoQuality.p720
        var ext = "mp4"
        var existing: String?
        var speedLimit: Int64?
        /// T17-CR07: the app-wide speed limit.
        var globalLimit: Int64?
        var title = "My Clip"
        var expected: String
        var testDescription: String { label }
    }

    @Test(arguments: [
        SuccessRow(label: "named from the title", expected: "My Clip.mp4"),
        SuccessRow(label: "title with dots keeps them", title: "Ep. 3 v1.2", expected: "Ep. 3 v1.2.mp4"),
        SuccessRow(label: "typed name kept", fileName: "Typed", expected: "Typed.mp4"),
        SuccessRow(label: "typed name sanitized again", fileName: "a/b:c", expected: FileNameResolver.sanitize("a/b:c") + ".mp4"),
        SuccessRow(label: "name already taken", existing: "My Clip.mp4", expected: "taken"),
        SuccessRow(label: "sound only", quality: .audio, ext: "m4a", expected: "My Clip.m4a"),
        SuccessRow(label: "speed limit passed on", speedLimit: 500_000, expected: "My Clip.mp4"),
        SuccessRow(label: "T17-CR07 app-wide limit applies", globalLimit: 300_000, expected: "My Clip.mp4"),
        SuccessRow(label: "T17-CR07 the lower limit wins", speedLimit: 500_000, globalLimit: 300_000, expected: "My Clip.mp4"),
        SuccessRow(label: "T17-CR07 own limit lower than app-wide (guard)", speedLimit: 100_000, globalLimit: 300_000, expected: "My Clip.mp4"),
    ])
    func t17_07_downloadsThroughTheTool(row: SuccessRow) async throws {
        let fake = try FakeYtDlp(ext: row.ext, title: row.title)
        let temp = TempDir()
        let engine = makeEngine(fake, temp: temp)
        engine.limiter.globalLimit = row.globalLimit
        var item = videoItem(temp, quality: row.quality, fileName: row.fileName)
        item.speedLimit = row.speedLimit
        let folder = URL(fileURLWithPath: item.directory, isDirectory: true)
        var expected = row.expected
        if let existing = row.existing {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: folder.appendingPathComponent(existing))
            expected = FileNameResolver.uniqueURL(for: folder.appendingPathComponent(existing)).lastPathComponent
        }
        let run = start(engine, item)
        let result = try await run.recorder.waitForFinish()

        #expect(result.status == .completed)
        #expect(result.fileName == expected)
        #expect(try Data(contentsOf: folder.appendingPathComponent(expected)) == Data("0123456789".utf8))
        #expect(result.totalBytes == 10 && result.downloadedBytes == 10)
        #expect(run.recorder.downloaded == 150, "picture and sound parts add up")
        #expect(fake.workFolderExisted)
        #expect(!FileManager.default.fileExists(atPath: run.workFolder.path), "the work folder is removed when done")
        #expect(fake.arguments == YtDlp.arguments(
            url: item.url, quality: row.quality, workFolder: run.workFolder, ffmpegPath: nil,
            speedLimit: [row.speedLimit, row.globalLimit].compactMap { $0 }.min(), cookiesFile: nil, cookiesFromBrowser: nil
        ))
    }

    @Test func t17_07_toolRunsWithHomebrewOnItsSearchPath() async throws {
        let fake = try FakeYtDlp()
        let temp = TempDir()
        let run = start(makeEngine(fake, temp: temp), videoItem(temp))
        _ = try await run.recorder.waitForFinish()
        #expect(fake.recorded("path.txt") == YtDlp.searchPath(executable: fake.path, inherited: Self.finderPath))
        #expect(fake.recorded("home.txt") == "/tmp/fake-home", "the rest of the environment is passed on")
    }

    struct FailureRunRow: Sendable, CustomTestStringConvertible {
        var label: String
        var mode: String
        var url = "https://www.youtube.com/watch?v=\(YtDlpTests.id)"
        var missingTool = false
        var expected: String
        var launched = true
        var testDescription: String { label }
    }

    @Test(arguments: [
        FailureRunRow(label: "tool not installed", mode: "", missingTool: true, expected: YtDlp.missingMessage, launched: false),
        FailureRunRow(label: "video unavailable", mode: "fail", expected: "Video unavailable"),
        FailureRunRow(label: "bot check", mode: "bot", expected: YtDlp.botCheckMessage),
        FailureRunRow(label: "stopped without a reason", mode: "silentfail", expected: "yt-dlp stopped (code 1)"),
        FailureRunRow(label: "finished without a file", mode: "nofile", expected: YtDlp.noFileMessage),
        FailureRunRow(label: "only a partial file left", mode: "partial", expected: YtDlp.noFileMessage),
        FailureRunRow(label: "playlist link", mode: "", url: "https://www.youtube.com/playlist?list=\(YtDlpTests.list)", expected: YtDlp.playlistMessage, launched: false),
    ])
    func t17_08_failuresSayWhy(row: FailureRunRow) async throws {
        let fake = try FakeYtDlp(mode: row.mode)
        let temp = TempDir()
        let engine = makeEngine(row.missingTool ? nil : fake, temp: temp, path: row.missingTool ? temp.file("nowhere/yt-dlp").path : nil)
        let item = videoItem(temp, url: row.url, cookies: "SID=\(Self.secret)")
        let run = start(engine, item)
        let result = try await run.recorder.waitForFinish()
        #expect(result.status == .failed)
        #expect(result.errorMessage == row.expected)
        #expect(fake.launched == row.launched)
        #expect(!(result.errorMessage ?? "").contains(Self.secret))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: item.directory)) ?? []
        #expect(leftovers.isEmpty, "nothing reaches the download folder")
        #expect(!FileManager.default.fileExists(atPath: run.workFolder.appendingPathComponent("cookies.txt").path))
    }

    @Test func t17_08_finishedFileWithoutItsLineIsStillUsed() async throws {
        let fake = try FakeYtDlp(mode: "leftover")
        let temp = TempDir()
        let run = start(makeEngine(fake, temp: temp), videoItem(temp))
        let result = try await run.recorder.waitForFinish()
        #expect(result.status == .completed)
        #expect(result.fileName == "My Clip.mp4")
    }

    @Test func t17_08_pauseKeepsThePartialFileAndResumes() async throws {
        let fake = try FakeYtDlp(mode: "slow")
        let temp = TempDir()
        let engine = makeEngine(fake, temp: temp)
        let item = videoItem(temp, cookies: "SID=\(Self.secret)")
        let first = start(engine, item)
        try await first.recorder.waitUntil { first.recorder.downloaded >= 10 }
        first.runner.pause()
        let paused = try await first.recorder.waitForFinish(timeout: 10)
        #expect(paused.status == .stopped)
        #expect(FileManager.default.fileExists(atPath: first.workFolder.appendingPathComponent("My Clip.mp4.part").path))
        #expect(!FileManager.default.fileExists(atPath: first.workFolder.appendingPathComponent("cookies.txt").path), "no sign-in left on disk while paused")

        fake.setMode("")
        let second = start(engine, paused)
        let done = try await second.recorder.waitForFinish()
        #expect(done.status == .completed)
        #expect(fake.recorded("cookies-seen.txt") == YtDlp.cookieFile(header: "SID=\(Self.secret)", site: .youtube), "the cookie file is written again on resume")
    }

    /// T17-CR01: a pause that lands while yt-dlp is being started still stops it.
    @Test func t17_cr01_pauseJustBeforeLaunchStopsTheTool() async throws {
        let fake = try FakeYtDlp(mode: "slow")
        let temp = TempDir()
        let engine = makeEngine(fake, temp: temp)
        let item = videoItem(temp)
        let recorder = JobRecorder()
        let job = try #require(engine.makeRunner(for: item) { recorder.handle($0) } as? YtDlpJob)
        job.beforeLaunch = { [weak job] in job?.pause() }
        job.start()
        let result = try await recorder.waitForFinish(timeout: 10)
        #expect(result.status == .stopped)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: item.directory)) ?? []).isEmpty)
    }

    /// T17-CR05: a tool that ignores the polite signals is ended for good.
    @Test func t17_cr05_stubbornToolIsKilled() async throws {
        let fake = try FakeYtDlp(mode: "stubborn")
        let temp = TempDir()
        let run = start(makeEngine(fake, temp: temp, stopGrace: 0.3), videoItem(temp))
        try await run.recorder.waitUntil { run.recorder.downloaded >= 10 }
        run.runner.pause()
        let result = try await run.recorder.waitForFinish(timeout: 10)
        #expect(result.status == .stopped)
    }

    /// T17-CR11: running yt-dlp downloads do not hold the shared worker threads that other downloads need.
    @Test func t17_cr11_runningDownloadsLeaveSharedThreadsFree() async throws {
        let fake = try FakeYtDlp(mode: "slow")
        let temp = TempDir()
        let engine = makeEngine(fake, temp: temp, stopGrace: 0.3)
        let runs = (0..<80).map { _ in start(engine, videoItem(temp)) }
        defer { runs.forEach { $0.runner.pause() } }
        try await JobRecorder().waitUntil(timeout: 20) { runs.allSatisfy { $0.recorder.downloaded >= 10 } }
        let ran = LockedFlag()
        DispatchQueue.global().async { ran.set() }
        try await JobRecorder().waitUntil(timeout: 3) { ran.isSet }
        runs.forEach { $0.runner.pause() }
        for run in runs { _ = try await run.recorder.waitForFinish(timeout: 15) }
    }

    @Test func t17_09_engineRunsVideoPagesThroughTheTool() {
        let temp = TempDir()
        let engine = makeEngine(nil, temp: temp)
        var item = videoItem(temp)
        #expect(engine.makeRunner(for: item) { _ in } is YtDlpJob)
        item.kind = .file
        #expect(engine.makeRunner(for: item) { _ in } is DownloadJob)
        item.kind = .hls(variantIndex: nil)
        #expect(engine.makeRunner(for: item) { _ in } is HLSJob)
    }

    struct CookieRunRow: Sendable, CustomTestStringConvertible {
        var label: String
        var url = "https://www.youtube.com/watch?v=\(YtDlpTests.id)"
        var cookies: String?
        var browser: String?
        var expectedFile: Bool
        var expectedBrowser: String?
        /// T19-05: the site whose domain the sign-in file names.
        var site = WebVideoSite.youtube
        var testDescription: String { label }
    }

    @Test(arguments: [
        CookieRunRow(label: "sign-in from the add-on", cookies: "SID=\(secret); b=2", expectedFile: true),
        CookieRunRow(label: "add-on sign-in wins over the browser setting", cookies: "SID=\(secret)", browser: "chrome", expectedFile: true),
        CookieRunRow(label: "browser setting when the add-on sent none", browser: "safari", expectedFile: false, expectedBrowser: "safari"),
        CookieRunRow(label: "neither", expectedFile: false),
        CookieRunRow(label: "unusable header falls back to the browser", cookies: "junk", browser: "chrome", expectedFile: false, expectedBrowser: "chrome"),
        CookieRunRow(label: "never sent to other sites", url: "https://video.example/watch?v=1", cookies: "SID=\(secret)", expectedFile: false),
        // T19-05
        CookieRunRow(label: "Facebook sign-in", url: "https://www.facebook.com/watch/?v=1", cookies: "c_user=\(secret); xs=2", expectedFile: true, site: .facebook),
        CookieRunRow(label: "fb.watch sign-in", url: "https://fb.watch/AbC1/", cookies: "c_user=\(secret)", expectedFile: true, site: .facebook),
        CookieRunRow(label: "Facebook page that is not a video (guard)", url: "https://www.facebook.com/somepage", cookies: "c_user=\(secret)", expectedFile: false),
        CookieRunRow(label: "Facebook without sign-in uses the browser setting (guard)", url: "https://www.facebook.com/reel/1", browser: "chrome", expectedFile: false, expectedBrowser: "chrome"),
    ])
    func t17_17_passesTheYouTubeSignIn(row: CookieRunRow) async throws {
        let fake = try FakeYtDlp()
        let temp = TempDir()
        let item = videoItem(temp, url: row.url, cookies: row.cookies)
        let run = start(makeEngine(fake, temp: temp, browser: row.browser), item)
        let result = try await run.recorder.waitForFinish()
        #expect(result.status == .completed)
        let arguments = fake.arguments
        let cookieFile = run.workFolder.appendingPathComponent("cookies.txt").path
        #expect(arguments.contains("--cookies") == row.expectedFile)
        if row.expectedFile {
            #expect(arguments.contains(cookieFile))
            #expect(fake.recorded("cookies-seen.txt") == YtDlp.cookieFile(header: row.cookies, site: row.site))
            #expect(fake.recorded("cookies-mode.txt") == "600", "only the user can read the sign-in")
        } else {
            #expect(fake.recorded("cookies-seen.txt") == nil)
        }
        if let browser = row.expectedBrowser {
            #expect(arguments.contains("--cookies-from-browser") && arguments.contains(browser))
        } else {
            #expect(!arguments.contains("--cookies-from-browser"))
        }
        #expect(!arguments.contains { $0.contains(Self.secret) }, "the sign-in never appears on the command line")
        #expect(!FileManager.default.fileExists(atPath: cookieFile))
    }
}

/// A stand-in for yt-dlp: a shell script that records how it was started and behaves as `mode` says.
final class FakeYtDlp: @unchecked Sendable {
    let dir = TempDir()
    var path: String { dir.file("yt-dlp").path }

    init(mode: String = "", ext: String = "mp4", title: String = "My Clip") throws {
        let script = #"""
        #!/bin/sh
        here=$(cd "$(dirname "$0")" && pwd)
        printf '%s\n' "$@" > "$here/args.txt"
        printf '%s' "$PATH" > "$here/path.txt"
        printf '%s' "$HOME" > "$here/home.txt"
        touch "$here/launched"
        mode=$(cat "$here/mode" 2>/dev/null)
        ext=$(cat "$here/ext" 2>/dev/null)
        title=$(cat "$here/title" 2>/dev/null)
        work=""; cookies=""; previous=""
        for argument in "$@"; do
          [ "$previous" = "-P" ] && work="$argument"
          [ "$previous" = "--cookies" ] && cookies="$argument"
          previous="$argument"
        done
        if [ -n "$cookies" ]; then
          cat "$cookies" > "$here/cookies-seen.txt"
          stat -f %Lp "$cookies" | tr -d '\n' > "$here/cookies-mode.txt"
        fi
        [ -d "$work" ] && touch "$here/work-existed"
        case "$mode" in
          fail) echo "ERROR: [youtube] abc123def45: Video unavailable" >&2; exit 1 ;;
          bot) echo "ERROR: [youtube] abc123def45: Sign in to confirm you’re not a bot." >&2; exit 1 ;;
          silentfail) exit 1 ;;
          nofile) echo "[cdl-title] My Clip"; exit 0 ;;
          partial) printf 'x' > "$work/My Clip.$ext.part"; exit 0 ;;
          leftover) echo "[cdl-title] My Clip"; printf 'abcdef' > "$work/My Clip.$ext"; exit 0 ;;
          playlist) printf 'aaaaaaaaaaa\tFirst: one/two\nbbbbbbbbbbb\tSecond\nccccccccccc\t[Private video]\naaaaaaaaaaa\tFirst again\n'; exit 0 ;;
          playlistempty) exit 0 ;;
          stubborn) trap '' INT TERM; echo "[cdl-title] My Clip"; echo "[cdl] 10 100 NA 5"; exec sleep 30 ;;
          slowtrap) trap 'mkdir -p "$work"; printf late > "$work/late.part"; touch "$here/trapped"; kill $! 2>/dev/null; exit 130' INT TERM; echo "[cdl-title] My Clip"; echo "[cdl] 10 100 NA 5"; sleep 30 & wait ;;
          hang) exec sleep 30 ;;
          slow) echo "[cdl-title] My Clip"; echo "[cdl] 10 100 NA 5"; printf 'part' > "$work/My Clip.$ext.part"; exec sleep 30 ;;
        esac
        echo "[cdl-title] $title"
        echo "[cdl] 100 100 NA 5"
        echo "[cdl] 10 50 NA 5"
        echo "[cdl] 50 50 NA 5"
        printf '0123456789' > "$work/$title.$ext"
        echo "[cdl-file] $work/$title.$ext"
        """#
        try Data(script.utf8).write(to: dir.file("yt-dlp"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        try Data(ext.utf8).write(to: dir.file("ext"))
        try Data(title.utf8).write(to: dir.file("title"))
        setMode(mode)
    }

    func setMode(_ mode: String) {
        try? Data(mode.utf8).write(to: dir.file("mode"))
    }

    func recorded(_ name: String) -> String? {
        try? String(contentsOf: dir.file(name), encoding: .utf8)
    }

    var arguments: [String] {
        (recorded("args.txt") ?? "").split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    var launched: Bool { FileManager.default.fileExists(atPath: dir.file("launched").path) }
    var workFolderExisted: Bool { FileManager.default.fileExists(atPath: dir.file("work-existed").path) }
}
