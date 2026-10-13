import Foundation
import Testing
@testable import cDownloaderCore

/// Serves pages and file sizes from a dictionary; records which pages were fetched.
final class FakeGrabberFetcher: GrabberFetching, @unchecked Sendable {
    let pages: [String: String]
    let sizes: [String: Int64]
    private let lock = NSLock()
    private var _fetched: [String] = []

    init(pages: [String: String], sizes: [String: Int64] = [:]) {
        self.pages = pages
        self.sizes = sizes
    }

    var fetched: [String] { lock.withLock { _fetched } }

    func page(_ url: URL) async throws -> (html: String?, finalURL: URL) {
        lock.withLock { _fetched.append(url.absoluteString) }
        guard let html = pages[url.absoluteString] else { throw DownloadFailure.http(404) }
        return (html, url)
    }

    func info(_ url: URL, referer: URL) async -> (size: Int64?, contentType: String?) {
        (sizes[url.absoluteString], nil)
    }
}

@Suite struct GrabberTests {
    // MARK: T12-01

    struct LinkRow: Sendable, CustomTestStringConvertible {
        var label: String
        var html: String
        var expected: [String]
        var testDescription: String { label }
    }

    @Test(arguments: [
        LinkRow(label: "a href", html: #"<a href="file.zip">x</a><A HREF='/abs.pdf'>y</A>"#, expected: ["https://h.example/dir/file.zip", "https://h.example/abs.pdf"]),
        LinkRow(label: "img and srcset", html: #"<img src="a.jpg" srcset="b.jpg 1x, c.jpg 2x"><source srcset="d.webp 640w">"#, expected: ["https://h.example/dir/a.jpg", "https://h.example/dir/b.jpg", "https://h.example/dir/c.jpg", "https://h.example/dir/d.webp"]),
        LinkRow(label: "media and frames", html: #"<video src="v.mp4" poster="p.png"></video><audio src=s.mp3></audio><iframe src="f.html"></iframe><link rel="stylesheet" href="st.css">"#, expected: ["https://h.example/dir/v.mp4", "https://h.example/dir/p.png", "https://h.example/dir/s.mp3", "https://h.example/dir/f.html", "https://h.example/dir/st.css"]),
        LinkRow(label: "base href", html: #"<base href="https://cdn.example/assets/"><img src="x.png">"#, expected: ["https://cdn.example/assets/x.png"]),
        LinkRow(label: "relative forms", html: #"<a href="../up.zip"></a><a href="//cdn.example/x.zip"></a><a href="?q=1"></a>"#, expected: ["https://h.example/up.zip", "https://cdn.example/x.zip", "https://h.example/dir/page.html?q=1"]),
        LinkRow(label: "fragments and junk", html: ##"<a href="a.html#top"></a><a href="javascript:void(0)"></a><a href="mailto:a@b.c"></a><a href="#only"></a><a href="a.html"></a>"##, expected: ["https://h.example/dir/a.html"]),
        LinkRow(label: "entities", html: #"<a href="get?id=1&amp;f=2">x</a>"#, expected: ["https://h.example/dir/get?id=1&f=2"]),
        LinkRow(label: "malformed", html: #"<a href="ok.zip"<<img src=<a href=">>"#, expected: ["https://h.example/dir/ok.zip"]),
    ])
    func t12_01_extractsLinks(row: LinkRow) {
        let links = HTMLLinkExtractor.links(in: row.html, baseURL: URL(string: "https://h.example/dir/page.html")!)
        #expect(links.map(\.absoluteString) == row.expected)
    }

    // MARK: T12-02

    struct Site {
        let main: LocalHTTPServer
        let other: LocalHTTPServer
        var start: URL { main.url("/sec/index.html") }
    }

    func makeSite() throws -> Site {
        let main = try LocalHTTPServer()
        let other = try LocalHTTPServer()
        func page(_ server: LocalHTTPServer, _ path: String, _ body: String) {
            server.set(path, .init(body: Data("<html><body>\(body)</body></html>".utf8), contentType: "text/html"))
        }
        func file(_ server: LocalHTTPServer, _ path: String, size: Int = 100) {
            server.set(path, .init(body: Data(count: size), contentType: "image/jpeg"))
        }
        page(main, "/sec/index.html", """
            <a href="page2.html">2</a> <img src="img1.jpg"> <a href="../top.html">top</a>
            <a href="\(other.url("/other.html").absoluteString)">other</a> <a href="logout.html">bye</a>
            <a href="skip/page.html">skip</a> <a href="index.html">self</a>
            """)
        page(main, "/sec/page2.html", #"<img src="img2.jpg"><a href="page3.html">3</a><a href="index.html">back</a><a href="missing.html">x</a>"#)
        page(main, "/sec/page3.html", #"<img src="img3.jpg">"#)
        page(main, "/top.html", #"<img src="sec/img-top.jpg">"#)
        page(main, "/sec/logout.html", #"<img src="img-logout.jpg">"#)
        page(main, "/sec/skip/page.html", #"<img src="img-skip.jpg">"#)
        page(other, "/other.html", #"<img src="img-other.jpg">"#)
        for name in ["img1", "img2", "img3", "img-top", "img-logout", "img-skip"] { file(main, "/sec/\(name).jpg") }
        file(other, "/img-other.jpg")
        return Site(main: main, other: other)
    }

    func names(_ result: GrabberResult) -> Set<String> {
        Set(result.files.map(\.url.lastPathComponent))
    }

    func settings(_ site: Site, _ configure: (inout GrabberSettings) -> Void = { _ in }) -> GrabberSettings {
        var settings = GrabberSettings(startURL: site.start, saveFolder: "/tmp/grab", fileTypes: ["jpg"])
        settings.hideDuplicates = false
        configure(&settings)
        return settings
    }

    @Test func t12_02_levelsOnThisSiteControlDepth() async throws {
        let site = try makeSite()
        let one = await SiteGrabber(settings: settings(site) { $0.levelsOnThisSite = 1 }).run()
        #expect(names(one) == ["img1.jpg"])
        let two = await SiteGrabber(settings: settings(site) { $0.levelsOnThisSite = 2 }).run()
        #expect(names(two) == ["img1.jpg", "img2.jpg", "img-top.jpg", "img-skip.jpg"])
        let three = await SiteGrabber(settings: settings(site) { $0.levelsOnThisSite = 3 }).run()
        #expect(names(three).contains("img3.jpg"))
        #expect(site.main.requests(for: "/sec/index.html").count == 3, "one fetch of the start page per run despite the cycle")
        #expect(site.main.requests(for: "/sec/logout.html").isEmpty, "logout pages are never opened")
    }

    @Test func t12_02_otherSitesNeedLevels() async throws {
        let site = try makeSite()
        let stay = await SiteGrabber(settings: settings(site) { $0.levelsOnOtherSites = 0 }).run()
        #expect(!names(stay).contains("img-other.jpg"))
        #expect(site.other.requests(for: "/other.html").isEmpty)
        let leave = await SiteGrabber(settings: settings(site) { $0.levelsOnOtherSites = 1 }).run()
        #expect(names(leave).contains("img-other.jpg"))
        let thisSiteOnly = await SiteGrabber(settings: settings(site) {
            $0.levelsOnOtherSites = 1
            $0.filesOnThisSiteOnly = true
        }).run()
        #expect(!names(thisSiteOnly).contains("img-other.jpg"))
    }

    @Test func t12_02_parentDirectoriesAndExploreFilters() async throws {
        let site = try makeSite()
        let noParents = await SiteGrabber(settings: settings(site) { $0.dontExploreParentDirectories = true }).run()
        #expect(!names(noParents).contains("img-top.jpg"))
        #expect(site.main.requests(for: "/top.html").isEmpty)
        let excluded = await SiteGrabber(settings: settings(site) { $0.exploreExclude = ["*skip*"] }).run()
        #expect(!names(excluded).contains("img-skip.jpg"))
        let included = await SiteGrabber(settings: settings(site) { $0.exploreInclude = ["*/sec/index.html", "*page2*"] }).run()
        #expect(names(included) == ["img1.jpg", "img2.jpg"])
    }

    @Test func t12_02_mainDomainOptionExploresSubdomains() async {
        let fetcher = FakeGrabberFetcher(pages: [
            "http://www.example.com/index.html": #"<a href="http://cdn.example.com/p.html">c</a><a href="http://evil.org/p.html">e</a>"#,
            "http://cdn.example.com/p.html": #"<img src="c.jpg">"#,
            "http://evil.org/p.html": #"<img src="e.jpg">"#,
        ])
        var settings = GrabberSettings(startURL: URL(string: "http://www.example.com/index.html")!, saveFolder: "/tmp", fileTypes: ["jpg"])
        settings.exploreWholeMainDomain = true
        let result = await SiteGrabber(settings: settings, fetcher: fetcher).run()
        #expect(Set(result.files.map(\.url.absoluteString)) == ["http://cdn.example.com/c.jpg"])
        #expect(!fetcher.fetched.contains("http://evil.org/p.html"))
        #expect(GrabberRules.mainDomain(of: "www.games.tonec.com") == "tonec.com")
    }

    // MARK: T12-03

    struct FileRow: Sendable, CustomTestStringConvertible {
        var label: String
        var url: String
        var size: Int64?
        var configure: @Sendable (inout GrabberSettings) -> Void
        var accepted: Bool
        var testDescription: String { label }
    }

    @Test(arguments: [
        FileRow(label: "type listed", url: "https://h.example/a/x.JPG", size: 10, configure: { _ in }, accepted: true),
        FileRow(label: "type not listed", url: "https://h.example/a/x.png", size: 10, configure: { _ in }, accepted: false),
        FileRow(label: "include match", url: "https://h.example/a/image01.jpg", size: 10, configure: { $0.fileInclude = ["image*.jpg"] }, accepted: true),
        FileRow(label: "include miss", url: "https://h.example/a/photo.jpg", size: 10, configure: { $0.fileInclude = ["image*.jpg"] }, accepted: false),
        FileRow(label: "exclude", url: "https://h.example/thumbs/x.jpg", size: 10, configure: { $0.fileExclude = ["*/thumbs/*"] }, accepted: false),
        FileRow(label: "start page token", url: "https://h.example/a/x.jpg", size: 10, configure: { $0.fileInclude = ["<start page>*"] }, accepted: true),
        FileRow(label: "min boundary", url: "https://h.example/a/x.jpg", size: 100, configure: { $0.minimumSize = 100 }, accepted: true),
        FileRow(label: "below min", url: "https://h.example/a/x.jpg", size: 99, configure: { $0.minimumSize = 100 }, accepted: false),
        FileRow(label: "max boundary", url: "https://h.example/a/x.jpg", size: 500, configure: { $0.maximumSize = 500 }, accepted: true),
        FileRow(label: "above max", url: "https://h.example/a/x.jpg", size: 501, configure: { $0.maximumSize = 500 }, accepted: false),
        FileRow(label: "unknown size", url: "https://h.example/a/x.jpg", size: nil, configure: { $0.minimumSize = 100 }, accepted: true),
        FileRow(label: "this site only", url: "https://cdn.other/x.jpg", size: 10, configure: { $0.filesOnThisSiteOnly = true }, accepted: false),
        FileRow(label: "all types", url: "https://h.example/a/x.css", size: 10, configure: { $0.fileTypes = ["*"] }, accepted: true),
    ])
    func t12_03_fileFilters(row: FileRow) {
        var settings = GrabberSettings(startURL: URL(string: "https://h.example/a/index.html")!, saveFolder: "/tmp", fileTypes: ["jpg"])
        row.configure(&settings)
        let rules = GrabberRules(settings: settings)
        let url = URL(string: row.url)!
        #expect((rules.isWantedFileType(url) && rules.acceptsFile(url) && rules.acceptsSize(row.size)) == row.accepted)
    }

    @Test func t12_03_duplicatesNeedSameNameAndSize() {
        func file(_ path: String, _ size: Int64?) -> GrabberFile {
            GrabberFile(url: URL(string: "https://h.example\(path)")!, referer: URL(string: "https://h.example/")!, size: size, contentType: nil, checked: true, relativePath: "")
        }
        let files = [file("/a/x.jpg", 10), file("/b/x.jpg", 10), file("/c/x.jpg", 11), file("/d/y.jpg", 10)]
        #expect(GrabberRules.removingDuplicates(files).map(\.url.path) == ["/a/x.jpg", "/c/x.jpg", "/d/y.jpg"])
    }

    @Test func t12_03_resultsCarrySizeRefererAndSubfolders() async throws {
        let site = try makeSite()
        let result = await SiteGrabber(settings: settings(site) {
            $0.levelsOnThisSite = 1
            $0.useOriginalSubfolders = true
        }).run()
        let file = try #require(result.files.first)
        #expect(file.size == 100)
        #expect(file.referer == site.start)
        #expect(file.relativePath == "sec/img1.jpg")
        #expect(result.pagesExplored == 1)
    }

    // MARK: T12-04

    @Test func t12_04_projectRoundTripAndCorruptFile() throws {
        let dir = TempDir()
        var settings = GrabberSettings(startURL: URL(string: "https://h.example/")!, saveFolder: "/tmp/g", fileTypes: ["pdf"])
        settings.exploreExclude = ["*print*"]
        settings.minimumSize = 1000
        let project = GrabberProject(
            name: "Docs",
            settings: settings,
            files: [GrabberFile(url: URL(string: "https://h.example/a.pdf")!, referer: URL(string: "https://h.example/")!, size: 5000, contentType: "application/pdf", checked: false, relativePath: "a.pdf")],
            pagesExplored: 7,
            lastRun: Date(timeIntervalSince1970: 5000),
            schedule: QueueSchedule(startEnabled: true)
        )
        let store = JSONStore(fileURL: dir.file("p.json"), defaultValue: { [GrabberProject]() })
        try store.save([project])
        #expect(store.load() == [project])
        try Data("garbage".utf8).write(to: dir.file("p.json"))
        #expect(store.load().isEmpty)
        #expect(store.lastBackupURL != nil)
    }
}
